local record ECS
end

-- Define a concrete, FFI-backed archetype directly on a Teal record.
--
-- Example:
--   ecs.define!(do
--     local record Particle
--       tag: string
--     end
--   end, {
--     x = f32,
--     id = u32,
--   })
--
-- The component kind identifiers are compile-time tokens.  No component
-- descriptors, names, or dynamic dispatch survive in the generated Lua.
macro ECS.define!(definition: Statement, components: Expression)
  local BI = BLOCK_INDEXES

  local kinds = {
    i8  = { ctype = "int8_t",   teal = "integer", bytes = 1 },
    u8  = { ctype = "uint8_t",  teal = "integer", bytes = 1 },
    i16 = { ctype = "int16_t",  teal = "integer", bytes = 2 },
    u16 = { ctype = "uint16_t", teal = "integer", bytes = 2 },
    i32 = { ctype = "int32_t",  teal = "integer", bytes = 4 },
    u32 = { ctype = "uint32_t", teal = "integer", bytes = 4 },
    i64 = { ctype = "int64_t",  teal = "integer", bytes = 8 },
    u64 = { ctype = "uint64_t", teal = "integer", bytes = 8 },
    f32 = { ctype = "float",    teal = "number",  bytes = 4 },
    f64 = { ctype = "double",   teal = "number",  bytes = 8 },
  }

  local function identifier(value: string)
    local out = block("identifier")
    out.tk = value
    return out
  end

  local function quoted(value: string)
    local out = block("string")
    out.tk = string.format("%q", value)
    return out
  end

  expect(definition, "statements")
  if #definition == 1 and definition[1].kind == "do" then
    definition = definition[1][BI.DO.BODY]
    expect(definition, "statements")
  end
  if #definition ~= 1 then
    error("ecs.define! expects exactly one local record declaration", 2)
  end

  local localType = expect(definition[1], "local_type")
  local name = expect(localType[BI.LOCAL_TYPE.VAR], "identifier")
  local newtype = expect(localType[BI.LOCAL_TYPE.VALUE], "newtype")
  local typedecl = expect(newtype[BI.NEWTYPE.TYPEDECL], "typedecl")
  local recordType = typedecl[BI.TYPEDECL.TYPE]
  if recordType and recordType.kind == "generic_type" then
    recordType = recordType[BI.GENERIC_TYPE.BASE]
  end
  expect(recordType, "record")
  expect(components, "literal_table")
  if #components == 0 then
    error("ecs.define! needs at least one component", 2)
  end

  local recordBody = recordType[BI.RECORD.FIELDS]
  if not recordBody then
    recordBody = block("record_body")
    recordType[BI.RECORD.FIELDS] = recordBody
  end

  local integerFieldTemplate = ```
    local record __ECSField
      component: ffi.Array<integer>
    end
  ```
  local numberFieldTemplate = ```
    local record __ECSField
      component: ffi.Array<number>
    end
  ```
  local function templateField(template)
    local templateType =
      template[1][BI.LOCAL_TYPE.VALUE]
        [BI.NEWTYPE.TYPEDECL][BI.TYPEDECL.TYPE]
    return templateType[BI.RECORD.FIELDS][1]
  end

  local coreFieldTemplate = ```
    local record __ECSCore
      __index: any
      capacity: integer
      count: integer
      componentBytes: integer
    end
  ```
  local coreType =
    coreFieldTemplate[1][BI.LOCAL_TYPE.VALUE]
      [BI.NEWTYPE.TYPEDECL][BI.TYPEDECL.TYPE]
  for _, field in ipairs(coreType[BI.RECORD.FIELDS]) do
    table.insert(recordBody, clone(field))
  end

  local init = `{
    capacity = capacity,
    count = 0,
    componentBytes = 0,
  }`
  local copies = block("statements")
  local seen = {}
  local totalBytes = 0

  for _, component in ipairs(components) do
    expect(component, "literal_table_item")
    local key = expect(component[BI.LITERAL_TABLE_ITEM.KEY], "string")
    local kindToken = component[BI.LITERAL_TABLE_ITEM.VALUE]
    if not kindToken or
       (kindToken.kind ~= "identifier" and kindToken.kind ~= "variable") then
      error("ECS component kinds must be identifiers", 2)
    end
    local fieldName = key.tk:sub(2, -2)
    local kind = kinds[kindToken.tk]
    if not kind then
      error("unknown ECS component kind '" .. kindToken.tk .. "'", 2)
    end
    if seen[fieldName] then
      error("duplicate ECS component '" .. fieldName .. "'", 2)
    end
    seen[fieldName] = true

    local fieldNameBlock = identifier(fieldName)
    local field = clone(templateField(
      kind.teal == "integer" and integerFieldTemplate or numberFieldTemplate
    ))
    field[BI.RECORD_FIELD.NAME] = clone(fieldNameBlock)
    table.insert(recordBody, field)

    local ctype = quoted(kind.ctype .. "[?]")
    local item
    if kind.teal == "integer" then
      item = `{ component =
        ffi.new($ctype, capacity) as ffi.Array<integer>
      }`
    else
      item = `{ component =
        ffi.new($ctype, capacity) as ffi.Array<number>
      }`
    end
    item = item[1]
    item[BI.LITERAL_TABLE_ITEM.KEY] = quoted(fieldName)
    table.insert(init, item)

    local copyStatement = ```
      self.$fieldNameBlock[slot] = self.$fieldNameBlock[last]
    ```
    table.insert(copies, copyStatement[1])
    totalBytes = totalBytes + kind.bytes
  end

  local byteCount = block("integer")
  byteCount.tk = tostring(totalBytes)
  init[3][BI.LITERAL_TABLE_ITEM.VALUE] = clone(byteCount)

  local implementation = ```
    $name.__index = $name

    function $name.newECS(capacity: integer): $name
      assert(
        capacity > 0 and capacity == math.floor(capacity),
        "ECS capacity must be a positive integer"
      )
      local self = $init as $name
      return setmetatable(
        self as any,
        $name as metatable<any>
      ) as $name
    end

    function $name:allocate(): integer
      local slot = self.count
      assert(slot < self.capacity, "ECS archetype capacity exceeded")
      self.count = slot + 1
      return slot
    end

    function $name:allocateMany(requested?: number): integer, integer
      local available = self.capacity - self.count
      local count = math.min(
        math.max(math.floor(requested or 0), 0),
        available
      )
      local first = self.count
      self.count = first + count
      return first, count
    end

    function $name:removeSwap(slot: integer): integer
      local last = self.count - 1
      assert(slot >= 0 and slot <= last, "ECS slot is out of bounds")
      if slot < last then
      end
      self.count = last
      return last
    end

    function $name:clearEntities()
      self.count = 0
    end

    function $name:componentMemoryBytes(): integer
      return self.capacity * self.componentBytes
    end
  ```

  for _, statement in ipairs(implementation) do
    if statement.kind == "record_function" then
      local methodName = statement[BI.RECORD_FUNCTION.NAME]
      if methodName and methodName.tk == "removeSwap" then
        local methodBody = statement[BI.RECORD_FUNCTION.BODY]
        for _, bodyStatement in ipairs(methodBody) do
          if bodyStatement.kind == "if" then
            local branch = bodyStatement[1]
            local branchBody = branch[BI.IF_BLOCK.BODY]
            for _, copyStatement in ipairs(copies) do
              table.insert(branchBody, clone(copyStatement))
            end
            break
          end
        end
      end
    end
  end

  for _, statement in ipairs(implementation) do
    table.insert(definition, statement)
  end
  return definition
end

return ECS
