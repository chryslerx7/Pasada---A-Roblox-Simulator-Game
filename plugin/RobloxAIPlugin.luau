-- RobloxAI Studio Plugin (Pasada - Phase 2C-PREP Tooling)
-- Polls Bridge at 127.0.0.1:3847, executes whitelisted actions, reports results.
-- Supported actions: create_folder, create_script, create_model, create_part,
--   set_property, inspect_object, delete_object
-- create_part supports: className Part|Seat|VehicleSeat (default Part),
--   shape Block|Ball|Cylinder, rotation/Orientation in degrees.
-- set_property supports safe construction props + PrimaryPart (validated).
-- No arbitrary Lua execution. No unrestricted filesystem/shell access.

local HttpService = game:GetService("HttpService")

local BRIDGE_URL = "http://127.0.0.1:3847"
local POLL_INTERVAL = 1

-- ================= Helpers =================

local function splitPath(pathStr)
	local parts = {}
	for segment in string.gmatch(pathStr or "", "[^%.]+") do
		table.insert(parts, segment)
	end
	return parts
end

local function resolvePath(pathStr)
	if type(pathStr) ~= "string" or pathStr == "" then
		return nil, "path must be a non-empty string"
	end
	if pathStr == "game" then
		return game
	end
	local segments = splitPath(pathStr)
	if #segments == 0 then
		return nil, "invalid empty path"
	end
	local current = game
	for _, segment in ipairs(segments) do
		if current == game then
			-- Allow direct service lookup (Workspace, ServerScriptService, etc.)
			local child = game:FindFirstChild(segment)
			if not child then
				-- Try GetService for services not found as child name match
				local ok, svc = pcall(function()
					return game:GetService(segment)
				end)
				if ok and svc then
					current = svc
				else
					return nil, ("path segment not found: %s (full path: %s)"):format(segment, pathStr)
				end
			else
				current = child
			end
		else
			local child = current:FindFirstChild(segment)
			if not child then
				return nil, ("path segment not found: %s (full path: %s)"):format(segment, pathStr)
			end
			current = child
		end
	end
	return current
end

local function toVector3(value)
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" and #value == 3
		and tonumber(value[1]) and tonumber(value[2]) and tonumber(value[3]) then
		return Vector3.new(tonumber(value[1]), tonumber(value[2]), tonumber(value[3]))
	end
	return nil
end

local function toColor3(value)
	if typeof(value) == "Color3" then
		return value
	end
	if type(value) == "table" and #value == 3 then
		local r, g, b = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
		if r and g and b then
			return Color3.fromRGB(math.clamp(math.floor(r), 0, 255), math.clamp(math.floor(g), 0, 255), math.clamp(math.floor(b), 0, 255))
		end
	end
	return nil
end

local function toMaterial(value)
	if typeof(value) == "EnumItem" then
		return value
	end
	if type(value) == "string" then
		local ok, mat = pcall(function()
			return (Enum.Material :: any)[value]
		end)
		if ok and mat then
			return mat
		end
	end
	return nil
end

local ALLOWED_PART_CLASSES = {
	Part = true,
	Seat = true,
	VehicleSeat = true,
}

local function toPartShape(value)
	if typeof(value) == "EnumItem" then
		return value
	end
	if type(value) == "string" then
		if value ~= "Block" and value ~= "Ball" and value ~= "Cylinder" then
			return nil
		end
		local ok, shape = pcall(function()
			return (Enum.PartType :: any)[value]
		end)
		if ok and shape then
			return shape
		end
	end
	return nil
end

local function toOrientationDegrees(value)
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" then
		local x, y, z
		if #value == 3 then
			x, y, z = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
		elseif value.x ~= nil or value.y ~= nil or value.z ~= nil then
			x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
		elseif value.X ~= nil or value.Y ~= nil or value.Z ~= nil then
			x, y, z = tonumber(value.X), tonumber(value.Y), tonumber(value.Z)
		end
		if x and y and z then
			return Vector3.new(x, y, z)
		end
	end
	return nil
end

local function toPositionVector(value)
	if typeof(value) == "Vector3" then
		return value
	end
	if type(value) == "table" then
		if #value == 3 then
			return toVector3(value)
		end
		if value.x ~= nil or value.y ~= nil or value.z ~= nil then
			local x, y, z = tonumber(value.x), tonumber(value.y), tonumber(value.z)
			if x and y and z then
				return Vector3.new(x, y, z)
			end
			return nil
		end
	end
	return toVector3(value)
end

local function fullPathOf(instance)
	local parts = {}
	local current = instance
	while current and current ~= game do
		table.insert(parts, 1, current.Name)
		current = current.Parent
	end
	return table.concat(parts, ".")
end

-- ================= Actions =================

local function actionCreateFolder(data)
	local name = data.name
	local parentPath = data.parent
	if type(name) ~= "string" or name == "" then
		return false, "create_folder: 'name' (non-empty string) is required"
	end
	if type(parentPath) ~= "string" or parentPath == "" then
		return false, "create_folder: 'parent' path string is required"
	end
	local parent, err = resolvePath(parentPath)
	if not parent then
		return false, ("create_folder: parent not found: %s"):format(err)
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return true, { path = fullPathOf(folder), name = folder.Name, className = "Folder" }
end

local function actionCreateScript(data)
	local name = data.name
	local scriptType = data.scriptType
	local parentPath = data.parent
	local source = data.source
	if type(name) ~= "string" or name == "" then
		return false, "create_script: 'name' (non-empty string) is required"
	end
	if scriptType ~= "Script" and scriptType ~= "LocalScript" and scriptType ~= "ModuleScript" then
		return false, "create_script: 'scriptType' must be one of: Script, LocalScript, ModuleScript"
	end
	if type(parentPath) ~= "string" or parentPath == "" then
		return false, "create_script: 'parent' path string is required"
	end
	local parent, err = resolvePath(parentPath)
	if not parent then
		return false, ("create_script: parent not found: %s"):format(err)
	end
	local obj = Instance.new(scriptType)
	obj.Name = name
	if source ~= nil then
		if type(source) ~= "string" then
			obj:Destroy()
			return false, "create_script: 'source' must be a string"
		end
		obj.Source = source
	end
	obj.Parent = parent
	return true, { path = fullPathOf(obj), name = obj.Name, className = scriptType }
end

local function actionCreateModel(data)
	local name = data.name
	local parentPath = data.parent
	if type(name) ~= "string" or name == "" then
		return false, "create_model: 'name' (non-empty string) is required"
	end
	if type(parentPath) ~= "string" or parentPath == "" then
		return false, "create_model: 'parent' path string is required"
	end
	local parent, err = resolvePath(parentPath)
	if not parent then
		return false, ("create_model: parent not found: %s"):format(err)
	end
	local model = Instance.new("Model")
	model.Name = name
	model.Parent = parent
	return true, { path = fullPathOf(model), name = model.Name, className = "Model" }
end

local function actionCreatePart(data)
	local name = data.name or "AI_Part"
	local parentPath = data.parent or "Workspace"
	local className = data.className or "Part"
	if type(name) ~= "string" or name == "" then
		return false, "create_part: 'name' must be a non-empty string"
	end
	if type(className) ~= "string" or not ALLOWED_PART_CLASSES[className] then
		return false, "create_part: 'className' must be one of: Part, Seat, VehicleSeat"
	end
	local parent, err = resolvePath(parentPath)
	if not parent then
		return false, ("create_part: parent not found: %s"):format(err)
	end
	local position = Vector3.new(0, 5, 0)
	if data.position ~= nil then
		local p = toPositionVector(data.position)
		if not p then
			return false, "create_part: 'position' must be an array of 3 numbers [x, y, z] or {x,y,z}"
		end
		position = p
	end
	local size = Vector3.new(4, 1, 2)
	if data.size ~= nil then
		local s = toVector3(data.size)
		if not s then
			return false, "create_part: 'size' must be an array of 3 numbers [x, y, z]"
		end
		size = s
	end
	local rotation: Vector3? = nil
	local rotInput = data.rotation or data.orientation
	if rotInput ~= nil then
		rotation = toOrientationDegrees(rotInput)
		if not rotation then
			return false, "create_part: 'rotation'/'orientation' must be 3 numbers in degrees [x, y, z] or {x,y,z}"
		end
	end
	local shape = nil
	if data.shape ~= nil then
		shape = toPartShape(data.shape)
		if not shape then
			return false, "create_part: 'shape' must be one of: Block, Ball, Cylinder"
		end
	end
	local part
	local okCreate, createErr = pcall(function()
		part = Instance.new(className)
	end)
	if not okCreate or not part then
		return false, ("create_part: failed to create class %s: %s"):format(tostring(className), tostring(createErr))
	end
	local function fail(msg)
		pcall(function()
			part:Destroy()
		end)
		return false, msg
	end
	part.Name = name
	-- Size first (Ball/Cylinder derive dimensions from Size; setting before Parent is safest)
	do
		local ok, e = pcall(function()
			part.Size = size
		end)
		if not ok then
			return fail(("create_part: invalid 'size': %s"):format(tostring(e)))
		end
	end
	if shape ~= nil then
		local ok, e = pcall(function()
			(part :: any).Shape = shape
		end)
		if not ok then
			return fail(("create_part: 'shape' not supported for %s: %s"):format(className, tostring(e)))
		end
	end
	do
		local ok, e = pcall(function()
			part.Position = position
		end)
		if not ok then
			return fail(("create_part: invalid 'position': %s"):format(tostring(e)))
		end
	end
	if rotation ~= nil then
		local ok, e = pcall(function()
			(part :: any).Orientation = rotation
		end)
		if not ok then
			return fail(("create_part: invalid 'rotation': %s"):format(tostring(e)))
		end
	end
	part.Anchored = if data.anchored == nil then true else (data.anchored == true)
	if data.material ~= nil then
		local mat = toMaterial(data.material)
		if not mat then
			return fail(("create_part: invalid 'material': %s"):format(tostring(data.material)))
		end
		part.Material = mat
	end
	if data.transparency ~= nil then
		local t = tonumber(data.transparency)
		if not t or t < 0 or t > 1 then
			return fail("create_part: 'transparency' must be a number 0-1")
		end
		part.Transparency = t
	end
	if data.color ~= nil then
		local c = toColor3(data.color)
		if not c then
			return fail("create_part: 'color' must be an array of 3 numbers [r, g, b] 0-255")
		end
		part.Color = c
	end
	part.Parent = parent
	return true, { path = fullPathOf(part), name = part.Name, className = part.ClassName }
end

local SAFE_PROPERTIES = {
	Name = true,
	Anchored = true,
	Transparency = true,
	CanCollide = true,
	Size = true,
	Position = true,
	Orientation = true,
	Rotation = true,
	Shape = true,
	Color = true,
	Material = true,
	Massless = true,
	Density = true,
	Friction = true,
	Elasticity = true,
	FrictionWeight = true,
	ElasticityWeight = true,
	PrimaryPart = true,
}

local function setCustomPhysicalScalar(instance, field, num)
	-- Update one Density/Friction/Elasticity field via PhysicalProperties.new,
	-- preserving the other fields. Only for BaseParts.
	if not instance:IsA("BasePart") then
		return false, ("set_property: %s requires a BasePart"):format(field)
	end
	local current: PhysicalProperties
	do
		local ok, pp = pcall(function()
			return (instance :: any).CustomPhysicalProperties
		end)
		if ok and typeof(pp) == "PhysicalProperties" then
			current = pp
		else
			-- Fall back to current material defaults
			local ok2, def = pcall(function()
				return PhysicalProperties.new((instance :: any).Material)
			end)
			if ok2 then
				current = def
			else
				current = PhysicalProperties.new(1, 0.3, 0.5, 1, 1)
			end
		end
	end
	local density = current.Density
	local friction = current.Friction
	local elasticity = current.Elasticity
	local frictionWeight = current.FrictionWeight
	local elasticityWeight = current.ElasticityWeight
	if field == "Density" then
		density = num
	elseif field == "Friction" then
		friction = num
	elseif field == "Elasticity" then
		elasticity = num
	elseif field == "FrictionWeight" then
		frictionWeight = num
	elseif field == "ElasticityWeight" then
		elasticityWeight = num
	end
	local ok, e = pcall(function()
		(instance :: any).CustomPhysicalProperties = PhysicalProperties.new(density, friction, elasticity, frictionWeight, elasticityWeight)
	end)
	if not ok then
		return false, ("set_property failed: %s"):format(tostring(e))
	end
	return true
end

local function actionSetProperty(data)
	local pathStr = data.path
	local property = data.property
	local value = data.value
	if type(pathStr) ~= "string" or pathStr == "" then
		return false, "set_property: 'path' (non-empty string) is required"
	end
	if type(property) ~= "string" or not SAFE_PROPERTIES[property] then
		return false, "set_property: 'property' must be one of: Name, Anchored, Transparency, CanCollide, Size, Position, Orientation, Rotation, Shape, Color, Material, Massless, Density, Friction, Elasticity, FrictionWeight, ElasticityWeight, PrimaryPart"
	end
	local instance, err = resolvePath(pathStr)
	if not instance then
		return false, ("set_property: object not found: %s"):format(err)
	end
	-- PrimaryPart: model-only, validated descendant BasePart
	if property == "PrimaryPart" then
		if not instance:IsA("Model") then
			return false, "set_property: PrimaryPart target must be a Model"
		end
		if type(value) ~= "string" or value == "" then
			return false, "set_property: PrimaryPart value must be a part path string or child name"
		end
		local part: Instance?
		if string.find(value, "%.") then
			part = resolvePath(value)
			if not part then
				return false, ("set_property: PrimaryPart part not found: %s"):format(value)
			end
		else
			part = instance:FindFirstChild(value)
			if not part then
				return false, ("set_property: PrimaryPart child not found in model: %s"):format(value)
			end
		end
		if not part:IsA("BasePart") then
			return false, "set_property: PrimaryPart must be a BasePart (Part, Seat, or VehicleSeat)"
		end
		if not part:IsDescendantOf(instance) then
			return false, "set_property: PrimaryPart must be a descendant of the target Model"
		end
		local ok, e = pcall(function()
			(instance :: any).PrimaryPart = part
		end)
		if not ok then
			return false, ("set_property failed: %s"):format(tostring(e)))
		end
		return true, { path = fullPathOf(instance), property = property, primaryPart = fullPathOf(part) }
	end
	local ok, setErr
	if property == "Name" then
		if type(value) ~= "string" or value == "" then
			return false, "set_property: Name must be a non-empty string"
		end
		ok, setErr = pcall(function()
			instance.Name = value
		end)
	elseif property == "Anchored" or property == "CanCollide" or property == "Massless" then
		if not instance:IsA("BasePart") and (property == "Massless" or property == "Anchored" or property == "CanCollide") then
			-- Anchored/CanCollide/Massless only meaningful on BaseParts; still attempt safely
		end
		if type(value) ~= "boolean" then
			return false, ("set_property: %s must be a boolean"):format(property)
		end
		ok, setErr = pcall(function()
			(instance :: any)[property] = value
		end)
	elseif property == "Transparency" then
		local t = tonumber(value)
		if not t or t < 0 or t > 1 then
			return false, "set_property: Transparency must be a number 0-1"
		end
		ok, setErr = pcall(function()
			(instance :: any).Transparency = t
		end)
	elseif property == "Size" or property == "Position" then
		local vec = toVector3(value)
		if not vec then
			return false, ("set_property: %s must be an array of 3 numbers"):format(property)
		end
		ok, setErr = pcall(function()
			(instance :: any)[property] = vec
		end)
	elseif property == "Orientation" or property == "Rotation" then
		local vec = toOrientationDegrees(value)
		if not vec then
			return false, "set_property: Orientation/Rotation must be 3 numbers in degrees [x, y, z] or {x,y,z}"
		end
		ok, setErr = pcall(function()
			(instance :: any).Orientation = vec
		end)
	elseif property == "Color" then
		local c = toColor3(value)
		if not c then
			return false, "set_property: Color must be an array of 3 numbers [r, g, b] 0-255"
		end
		ok, setErr = pcall(function()
			(instance :: any).Color = c
		end)
	elseif property == "Material" then
		local mat = toMaterial(value)
		if not mat then
			return false, ("set_property: invalid Material: %s"):format(tostring(value))
		end
		ok, setErr = pcall(function()
			(instance :: any).Material = mat
		end)
	elseif property == "Shape" then
		local shape = toPartShape(value)
		if not shape then
			return false, "set_property: Shape must be one of: Block, Ball, Cylinder"
		end
		ok, setErr = pcall(function()
			(instance :: any).Shape = shape
		end)
	elseif property == "Density" or property == "Friction" or property == "Elasticity" or property == "FrictionWeight" or property == "ElasticityWeight" then
		local num = tonumber(value)
		if not num then
			return false, ("set_property: %s must be a number"):format(property)
		end
		if property == "Density" and (num < 0.01 or num > 100) then
			return false, "set_property: Density must be 0.01-100"
		end
		if property == "Friction" and (num < 0 or num > 2) then
			return false, "set_property: Friction must be 0-2"
		end
		if property == "Elasticity" and (num < 0 or num > 1) then
			return false, "set_property: Elasticity must be 0-1"
		end
		if (property == "FrictionWeight" or property == "ElasticityWeight") and (num < 0 or num > 100) then
			return false, ("set_property: %s must be 0-100"):format(property)
		end
		local sok, smsg = setCustomPhysicalScalar(instance, property, num)
		if not sok then
			return false, smsg
		end
		return true, { path = fullPathOf(instance), property = property }
	end
	if not ok then
		return false, ("set_property failed: %s"):format(tostring(setErr))
	end
	return true, { path = fullPathOf(instance), property = property }
end

local function actionInspectObject(data)
	local pathStr = data.path
	if type(pathStr) ~= "string" or pathStr == "" then
		return false, "inspect_object: 'path' (non-empty string) is required"
	end
	local instance, err = resolvePath(pathStr)
	if not instance then
		return false, ("inspect_object: object not found: %s"):format(err)
	end
	local children = {}
	for _, child in ipairs(instance:GetChildren()) do
		table.insert(children, { name = child.Name, className = child.ClassName, path = fullPathOf(child) })
	end
	table.sort(children, function(a, b)
		return a.name < b.name
	end)
	local props = {}
	local function tryRead(key, getter)
		local ok, val = pcall(getter)
		if ok then
			props[key] = val
		end
	end
	tryRead("Name", function()
		return instance.Name
	end)
	tryRead("ClassName", function()
		return instance.ClassName
	end)
	-- Common BasePart / Model / Script properties (best-effort)
	tryRead("Anchored", function()
		return (instance :: any).Anchored
	end)
	tryRead("CanCollide", function()
		return (instance :: any).CanCollide
	end)
	tryRead("Transparency", function()
		return (instance :: any).Transparency
	end)
	tryRead("Material", function()
		return tostring((instance :: any).Material)
	end)
	tryRead("Size", function()
		local s: Vector3 = (instance :: any).Size
		return { s.X, s.Y, s.Z }
	end)
	tryRead("Position", function()
		local p: Vector3 = (instance :: any).Position
		return { p.X, p.Y, p.Z }
	end)
	tryRead("Orientation", function()
		local o: Vector3 = (instance :: any).Orientation
		return { o.X, o.Y, o.Z }
	end)
	tryRead("Shape", function()
		return tostring((instance :: any).Shape)
	end)
	tryRead("Massless", function()
		return (instance :: any).Massless
	end)
	tryRead("Density", function()
		local pp = (instance :: any).CustomPhysicalProperties
		if typeof(pp) == "PhysicalProperties" then
			return pp.Density
		end
		return nil
	end)
	tryRead("Friction", function()
		local pp = (instance :: any).CustomPhysicalProperties
		if typeof(pp) == "PhysicalProperties" then
			return pp.Friction
		end
		return nil
	end)
	tryRead("Elasticity", function()
		local pp = (instance :: any).CustomPhysicalProperties
		if typeof(pp) == "PhysicalProperties" then
			return pp.Elasticity
		end
		return nil
	end)
	tryRead("PrimaryPart", function()
		if instance:IsA("Model") then
			local pp = (instance :: any).PrimaryPart
			if pp then
				return { name = pp.Name, path = fullPathOf(pp) }
			end
			return nil
		end
		return nil
	end)
	tryRead("Color", function()
		local c: Color3 = (instance :: any).Color
		return { math.floor(c.R * 255 + 0.5), math.floor(c.G * 255 + 0.5), math.floor(c.B * 255 + 0.5) }
	end)
	tryRead("Source", function()
		local src = (instance :: any).Source
		if type(src) == "string" then
			return string.sub(src, 1, 2000)
		end
		return nil
	end)
	return true, {
		name = instance.Name,
		className = instance.ClassName,
		path = fullPathOf(instance),
		children = children,
		childCount = #children,
		properties = props,
	}
end

local PROTECTED_SINGLE_SEGMENT = true

local function actionDeleteObject(data)
	local pathStr = data.path
	if type(pathStr) ~= "string" or pathStr == "" then
		return false, "delete_object: 'path' (non-empty string) is required"
	end
	local segments = splitPath(pathStr)
	if #segments <= 1 and PROTECTED_SINGLE_SEGMENT then
		return false, ("delete_object: refusing to delete top-level service: %s"):format(pathStr)
	end
	local instance, err = resolvePath(pathStr)
	if not instance then
		return false, ("delete_object: object not found: %s"):format(err)
	end
	local name = instance.Name
	local ok, delErr = pcall(function()
		instance:Destroy()
	end)
	if not ok then
		return false, ("delete_object failed: %s"):format(tostring(delErr))
	end
	return true, { deleted = pathStr, name = name }
end

local ACTION_HANDLERS = {
	create_folder = actionCreateFolder,
	create_script = actionCreateScript,
	create_model = actionCreateModel,
	create_part = actionCreatePart,
	set_property = actionSetProperty,
	inspect_object = actionInspectObject,
	delete_object = actionDeleteObject,
}

-- ================= Bridge I/O =================

local function reportResult(id, success, result, errMsg)
	local payload = {
		success = success,
		result = result,
		error = errMsg,
	}
	local json = HttpService:JSONEncode(payload)
	local ok, resp = pcall(function()
		return HttpService:PostAsync(
			BRIDGE_URL .. "/commands/" .. HttpService:UrlEncode(id) .. "/result",
			json,
			Enum.HttpContentType.ApplicationJson
		)
	end)
	if ok then
		print(("[RobloxAI] Reported %s -> %s"):format(id, if success then "success" else "failed"))
	else
		warn(("[RobloxAI] Failed to report %s: %s"):format(id, tostring(resp)))
	end
end

local function executeCommand(cmd)
	local id = cmd.id
	local action = cmd.action
	local data = cmd.data or {}
	if type(id) ~= "string" or id == "" then
		warn("[RobloxAI] Received command without id, skipping")
		return
	end
	local handler = ACTION_HANDLERS[action]
	if not handler then
		local msg = ("unsupported action: %s"):format(tostring(action))
		warn(("[RobloxAI] %s (%s)"):format(msg, id))
		reportResult(id, false, nil, msg)
		return
	end
	print(("[RobloxAI] Executing %s action=%s"):format(id, tostring(action)))
	local ok, success, resultOrErr = pcall(handler, data)
	if not ok then
		local msg = ("handler crashed: %s"):format(tostring(success))
		warn(("[RobloxAI] %s (%s)"):format(msg, id))
		reportResult(id, false, nil, msg)
		return
	end
	if success then
		reportResult(id, true, resultOrErr, nil)
	else
		reportResult(id, false, nil, tostring(resultOrErr))
	end
end

local function pollOnce()
	local body: string
	do
		local ok, resp = pcall(function()
			return HttpService:GetAsync(BRIDGE_URL .. "/commands")
		end)
		if not ok then
			-- Bridge offline; stay quiet except occasional warning
			return
		end
		body = resp
	end
	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(body)
	end)
	if not ok or type(decoded) ~= "table" then
		warn("[RobloxAI] Invalid JSON from Bridge /commands")
		return
	end
	local list = (decoded :: any).commands
	if type(list) ~= "table" then
		return
	end
	for _, cmd in ipairs(list) do
		if type(cmd) == "table" then
			-- Execute in protected mode so one bad command doesn't kill the loop
			local eok, eerr = pcall(executeCommand, cmd)
			if not eok then
				warn(("[RobloxAI] executeCommand crashed: %s"):format(tostring(eerr)))
				if type(cmd.id) == "string" then
					reportResult(cmd.id, false, nil, ("plugin crashed: %s"):format(tostring(eerr)))
				end
			end
		end
	end
end

print("[RobloxAI] Plugin loaded. Polling " .. BRIDGE_URL .. "/commands ...")

task.spawn(function()
	while true do
		local ok, err = pcall(pollOnce)
		if not ok then
			warn(("[RobloxAI] poll crashed: %s"):format(tostring(err)))
		end
		task.wait(POLL_INTERVAL)
	end
end)
