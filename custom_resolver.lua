-- Custom Resolver for Primordial.dev
-- Single-file implementation with FFI-based animation state access
-- Version: 1.0

-- =====================================
-- 1. FFI DEFINITIONS
-- =====================================
local ffi = require("ffi")

ffi.cdef[[
    typedef uintptr_t (__thiscall* GetClientEntity_t)(void*, int);
    
    struct CAnimstate {
        char pad[3];
        char m_bForceWeaponUpdate;
        char pad1[91];
        void* m_pBaseEntity;
        void* m_pActiveWeapon;
        void* m_pLastActiveWeapon;
        float m_flLastClientSideAnimationUpdateTime;
        int m_iLastClientSideAnimationUpdateFramecount;
        float m_flAnimUpdateDelta;
        float m_flEyeYaw;
        float m_flPitch;
        float m_flGoalFeetYaw;
        float m_flCurrentFeetYaw;
        float m_flCurrentTorsoYaw;
        float m_flUnknownVelocityLean;
        float m_flLeanAmount;
        char pad2[4];
        float m_flFeetCycle;
        float m_flFeetYawRate;
        char pad3[4];
        float m_fDuckAmount;
        float m_fLandingDuckAdditiveSomething;
        char pad4[4];
        float m_vOriginX;
        float m_vOriginY;
        float m_vOriginZ;
        float m_vLastOriginX;
        float m_vLastOriginY;
        float m_vLastOriginZ;
        float m_vVelocityX;
        float m_vVelocityY;
        char pad5[4];
        float m_flUnknownFloat1;
        char pad6[8];
        float m_flUnknownFloat2;
        float m_flUnknownFloat3;
        float m_flUnknown;
        float m_flSpeed2D;
        float m_flUpVelocity;
        float m_flSpeedNormalized;
        float m_flFeetSpeedForwardsOrSideWays;
        float m_flFeetSpeedUnknownForwardOrSideways;
        float m_flTimeSinceStartedMoving;
        float m_flTimeSinceStoppedMoving;
        bool m_bOnGround;
        bool m_bInHitGroundAnimation;
        float m_flTimeSinceInAir;
        float m_flLastOriginZ;
        float m_flHeadHeightOrOffsetFromHittingGroundAnimation;
        float m_flStopToFullRunningFraction;
        char pad7[4];
        float m_flMagicFraction;
        char pad8[60];
        float m_flWorldForce;
        char pad9[458];
        float m_flMinYaw;
        float m_flMaxYaw;
    };
    
    struct CCSGOPlayerAnimstate {
        void* vtable;
        bool m_bIsReset;
        bool m_bUnknownClientBool;
        char pad[2];
        float m_flFeetYawRate;
        float m_flFeetYawRateMoving;
        float m_flCurrentTorsoYaw;
        float m_flTimeToAlignLowerBody;
        float m_flPrimaryCycle;
        float m_flMoveWeight;
        float m_flMoveWeightSmoothed;
        float m_flAnimDuckAmount;
        float m_flDuckAdditional;
        float m_flRecrouchWeight;
        float m_flSpeedAsPortionOfCrouchSpeed;
        float m_flSpeedAsPortionOfWalkSpeed;
        float m_flSpeedAsPortionOfRunSpeed;
        float m_flTimeNotMoving;
        float m_flVelocityDifference;
    };
    
    struct AnimationLayer {
        char pad_0x0000[0x18];
        uint32_t m_nSequence;
        float m_flPrevCycle;
        float m_flWeight;
        float m_flWeightDeltaRate;
        float m_flCycle;
        float m_flPlaybackRate;
        char pad_0x0030[0x4];
    };
]]

-- =====================================
-- 2. MATHEMATICAL FUNCTIONS
-- =====================================
local function normalize_angle(angle)
    while angle > 180 do 
        angle = angle - 360 
    end
    while angle < -180 do 
        angle = angle + 360 
    end
    return angle
end

local function calculate_delta(angle1, angle2)
    return normalize_angle(angle1 - angle2)
end

local function clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

local function angle_to_vector(pitch, yaw)
    local p = math.rad(pitch)
    local y = math.rad(yaw)
    
    return {
        x = math.cos(p) * math.cos(y),
        y = math.cos(p) * math.sin(y),
        z = -math.sin(p)
    }
end

local function vector_to_angle(vector)
    local pitch = math.deg(math.atan2(-vector.z, math.sqrt(vector.x^2 + vector.y^2)))
    local yaw = math.deg(math.atan2(vector.y, vector.x))
    return pitch, yaw
end

-- =====================================
-- 3. MEMORY ACCESS FUNCTIONS
-- =====================================
local RawIEntityList = nil
local IEntityList = nil

local function init_interfaces()
    -- Get entity list interface using Primordial API
    local ok, result = pcall(function()
        RawIEntityList = ffi.cast("void***", memory.create_interface("client.dll", "VClientEntityList003"))
        if RawIEntityList then
            IEntityList = ffi.cast("GetClientEntity_t", RawIEntityList[0][3])
        end
    end)
    
    if not ok then
        print("[Resolver] Failed to initialize interfaces")
    end
end

local function get_entity_address(idx)
    if not RawIEntityList or not IEntityList then
        return nil
    end
    
    local ok, addr = pcall(function()
        return IEntityList(RawIEntityList, idx)
    end)
    
    return ok and addr or nil
end

local function get_animstate(player)
    local ok, result = pcall(function()
        if not player then return nil end
        
        local addr = get_entity_address(player:get_index())
        if not addr or addr == 0 then return nil end
        
        local player_ptr = ffi.cast("char*", addr)
        if not player_ptr then return nil end
        
        local animstate_ptr = player_ptr + 0x9960
        local animstate = ffi.cast("struct CAnimstate**", animstate_ptr)[0]
        
        if not animstate or ffi.cast("intptr_t", animstate) == 0 then
            return nil
        end
        
        return animstate
    end)
    
    return ok and result or nil
end

local function get_animation_layer(player, layer_idx)
    local ok, result = pcall(function()
        local addr = get_entity_address(player:get_index())
        if not addr then return nil end
        
        local player_ptr = ffi.cast("char*", addr)
        local animlayers = ffi.cast("struct AnimationLayer*", player_ptr + 0x2990)
        
        if layer_idx < 0 or layer_idx > 14 then return nil end
        
        return animlayers[layer_idx]
    end)
    
    return ok and result or nil
end

-- =====================================
-- 4. ANIMATION LAYER ANALYSIS
-- =====================================
local ANIMATION_LAYER = {
    AIMMATRIX = 0,
    WEAPON_ACTION = 1,
    WEAPON_ACTION_RECROUCH = 2,
    ADJUST = 3,
    MOVEMENT_JUMP_OR_FALL = 4,
    MOVEMENT_LAND_OR_CLIMB = 5,
    MOVEMENT_MOVE = 6,
    MOVEMENT_STRAFECHANGE = 7,
    WHOLE_BODY = 8,
    FLASHED = 9,
    FLINCH = 10,
    ALIVELOOP = 11,
    LEAN = 12
}

local function analyze_animation_layers(player)
    local layers = {}
    
    -- Try to get layers via FFI
    for i = 0, 14 do
        local layer = get_animation_layer(player, i)
        if layer then
            layers[i] = {
                weight = layer.m_flWeight,
                cycle = layer.m_flCycle,
                playback_rate = layer.m_flPlaybackRate,
                sequence = layer.m_nSequence
            }
        else
            layers[i] = {
                weight = 0,
                cycle = 0,
                playback_rate = 0,
                sequence = 0
            }
        end
    end
    
    return layers
end

local function detect_animation_state(layers)
    local state = {
        is_moving = false,
        is_jumping = false,
        is_crouching = false,
        is_fakewalking = false,
        is_desyncing = false
    }
    
    -- Movement detection
    if layers[ANIMATION_LAYER.MOVEMENT_MOVE] then
        state.is_moving = layers[ANIMATION_LAYER.MOVEMENT_MOVE].weight > 0.0
    end
    
    -- Jump/Fall detection
    if layers[ANIMATION_LAYER.MOVEMENT_JUMP_OR_FALL] then
        state.is_jumping = layers[ANIMATION_LAYER.MOVEMENT_JUMP_OR_FALL].weight > 0.0
    end
    
    -- Fakewalk detection
    if layers[ANIMATION_LAYER.MOVEMENT_MOVE] and layers[ANIMATION_LAYER.ALIVELOOP] then
        local move_weight = layers[ANIMATION_LAYER.MOVEMENT_MOVE].weight
        local alive_weight = layers[ANIMATION_LAYER.ALIVELOOP].weight
        state.is_fakewalking = move_weight > 0 and move_weight < 0.012 and alive_weight > 0.95
    end
    
    -- Desync detection through layer 12 (lean)
    if layers[ANIMATION_LAYER.LEAN] then
        state.is_desyncing = math.abs(layers[ANIMATION_LAYER.LEAN].weight) > 0.0
    end
    
    return state
end

-- =====================================
-- 5. MAIN RESOLVER
-- =====================================
local player_cache = {}
local resolver_data = {}
local last_resolve_tick = {}  -- Track when we last resolved each player

local function collect_player_data(player)
    local ok, result = pcall(function()
        if not player then return nil end
        
        -- Get animstate first (most important)
        local animstate = get_animstate(player)
        if not animstate then return nil end
        
        -- Get props safely
        local velocity = player:get_prop("m_vecVelocity") or {x = 0, y = 0, z = 0}
        local origin = player:get_prop("m_vecOrigin") or {x = 0, y = 0, z = 0}
        local duck = player:get_prop("m_flDuckAmount") or 0
        local flags = player:get_prop("m_fFlags") or 0
        
        local data = {
            animstate = animstate,
            layers = {},  -- Simplified - not needed for core resolver
            velocity = velocity,
            eye_angles = {yaw = 0, pitch = 0},
            flags = flags,
            duck_amount = duck,
            origin = origin
        }
        
        -- Get eye yaw from animstate (reliable source)
        data.eye_angles.yaw = animstate.m_flEyeYaw
        data.eye_angles.pitch = animstate.m_flPitch
        
        -- Calculate 2D velocity
        data.velocity_2d = math.sqrt(velocity.x^2 + velocity.y^2)
        
        return data
    end)
    
    return ok and result or nil
end

local function calculate_desync_direction(data)
    if not data or not data.animstate then return 0 end
    
    local animstate = data.animstate
    
    -- Safe access to animstate values
    local ok, direction = pcall(function()
        local goal_feet_yaw = animstate.m_flGoalFeetYaw
        local current_feet_yaw = animstate.m_flCurrentFeetYaw
        local body_lean = animstate.m_flLeanAmount
        local feet_cycle = animstate.m_flFeetCycle
        
        -- ===== MATHEMATICAL DETERMINATION FROM TЗ =====
        -- "Анализ через feet cycle и torso yaw"
        
        -- Calculate feet delta (from TЗ)
        local feet_delta = calculate_delta(goal_feet_yaw, current_feet_yaw)
        
        -- Primary: feet_delta > 35 (from TЗ)
        if math.abs(feet_delta) > 35 then
            return feet_delta > 0 and 1 or -1
        end
        
        -- Secondary: body lean (from TЗ - "body_lean > 0 and 1 or -1")
        if math.abs(body_lean) > 0.1 then
            return body_lean > 0 and 1 or -1
        end
        
        -- Fallback: use feet cycle
        if feet_cycle > 0.5 then
            return 1
        else
            return -1
        end
    end)
    
    return ok and direction or 0
end

local function calculate_resolved_angle(player, data, direction_modifier)
    if not data or not data.animstate or direction_modifier == 0 then
        return data and data.eye_angles.yaw or 0, 0
    end
    
    local ok, resolved_yaw, correction = pcall(function()
        local animstate = data.animstate
        
        -- Get animstate values
        local eye_yaw = animstate.m_flEyeYaw
        local goal_feet_yaw = animstate.m_flGoalFeetYaw
        local feet_yaw_rate = animstate.m_flFeetYawRate
        local body_lean = animstate.m_flLeanAmount
        local anim_delta = animstate.m_flAnimUpdateDelta
        
        -- Time delta for formula
        local time_delta = anim_delta
        if time_delta <= 0 or time_delta > 1.0 then
            time_delta = global_vars.interval_per_tick()
        end
        
        -- ===== TЗ FORMULA =====
        -- real_yaw = eye_yaw + (feet_yaw_rate * time_delta * direction_modifier)
        
        local result_yaw = eye_yaw + (feet_yaw_rate * time_delta * direction_modifier)
        
        -- ===== DESYNC CORRECTION =====
        local desync = calculate_delta(eye_yaw, goal_feet_yaw)
        local abs_desync = math.abs(desync)
        
        -- High desync = jitter, resolve to goal_feet_yaw (real position)
        if abs_desync > 35 then
            result_yaw = goal_feet_yaw + (body_lean * 45)
        elseif abs_desync > 20 then
            result_yaw = goal_feet_yaw + (body_lean * 40)
        elseif abs_desync > 10 then
            result_yaw = result_yaw + (body_lean * 30)
        end
        
        -- Movement adjustment
        if data.velocity_2d > 100 then
            local vel_x = animstate.m_vVelocityX
            local vel_y = animstate.m_vVelocityY
            
            if math.abs(vel_x) > 10 or math.abs(vel_y) > 10 then
                local move_yaw = math.deg(math.atan2(vel_y, vel_x))
                local move_delta = calculate_delta(move_yaw, eye_yaw)
                result_yaw = result_yaw + (move_delta * 0.12)
            end
        end
        
        -- Normalize
        result_yaw = normalize_angle(result_yaw)
        
        local corr = calculate_delta(result_yaw, eye_yaw)
        
        return result_yaw, math.abs(corr)
    end)
    
    if ok then
        return resolved_yaw, correction
    else
        return data.eye_angles.yaw, 0
    end
end

local function validate_resolution(player, resolved_angle, data)
    -- Check angle validity
    if math.abs(resolved_angle) > 180 then
        return false
    end
    
    -- Check physical constraints
    if data.animstate then
        local max_delta = 120 -- Maximum possible desync range
        local current_delta = math.abs(calculate_delta(resolved_angle, data.eye_angles.yaw))
        if current_delta > max_delta then
            return false
        end
    end
    
    return true
end

local function resolve_player(player)
    local ok, result = pcall(function()
        if not player or not player:is_alive() then
            return
        end
        
        local player_idx = player:get_index()
        local current_tick = global_vars.tick_count()
        
        -- ===== RATE LIMITING - Don't resolve every tick =====
        local last_tick = last_resolve_tick[player_idx] or 0
        local ticks_since_last = current_tick - last_tick
        
        -- Only resolve every 8 ticks (prevents freezing)
        if ticks_since_last < 8 then
            return
        end
        
        last_resolve_tick[player_idx] = current_tick
        
        -- Collect fresh data
        local data = collect_player_data(player)
        if not data or not data.animstate then
            return
        end
        
        -- Calculate desync direction
        local direction = calculate_desync_direction(data)
        
        if direction == 0 then
            return
        end
        
        -- Calculate resolved angle
        local resolved_yaw, desync_amount = calculate_resolved_angle(player, data, direction)
        
        -- Validate resolution
        if not validate_resolution(player, resolved_yaw, data) then
            return
        end
        
        -- Store resolver data (only if valid)
        if resolved_yaw and desync_amount then
            resolver_data[player_idx] = {
                original_yaw = data.eye_angles.yaw,
                resolved_yaw = resolved_yaw,
                desync_amount = desync_amount,
                direction = direction,
                tick = current_tick
            }
            
            -- Apply resolution ONLY via animstate
            -- Writing to memory - do it ONCE per resolve
            if data.animstate then
                data.animstate.m_flGoalFeetYaw = resolved_yaw
            end
            
            -- Log if enabled (only once per resolve)
            log_resolution(player:get_name(), data.eye_angles.yaw, resolved_yaw, desync_amount)
        end
    end)
    
    if not ok then
        -- Silently fail
    end
end

-- =====================================
-- 6. UI CREATION
-- =====================================
local menu_items = {
    enabled = menu.add_checkbox("Custom Resolver", "Resolver", false),
    logs = menu.add_checkbox("Custom Resolver", "Logs", false)
}

-- =====================================
-- 7. CALLBACKS
-- =====================================
local function on_create_move(cmd)
    if not menu_items.enabled:get() then
        return
    end
    
    local ok = pcall(function()
        local local_player = entity_list.get_local_player()
        if not local_player or not local_player:is_alive() then
            return
        end
        
        -- Resolve enemy players (with safety limit)
        local enemies = entity_list.get_players(true)
        if not enemies then return end
        
        local resolved_count = 0
        local max_resolve_per_tick = 3  -- Reduced from 5 to prevent freezing
        
        for _, player in pairs(enemies) do
            if resolved_count >= max_resolve_per_tick then
                break
            end
            
            if player and player:is_alive() and not player:is_dormant() then
                resolve_player(player)
                resolved_count = resolved_count + 1
            end
        end
    end)
end

local function on_paint()
    if not menu_items.enabled:get() then
        return
    end
    
    -- Clean up old data safely
    local ok = pcall(function()
        local current_tick = global_vars.tick_count()
        for idx, data in pairs(resolver_data) do
            if data and data.tick and (current_tick - data.tick > 64) then
                resolver_data[idx] = nil
            end
        end
    end)
end

-- =====================================
-- 8. LOGGING SYSTEM
-- =====================================
function log_resolution(player_name, original_yaw, resolved_yaw, desync_amount)
    if not menu_items.logs:get() then return end
    
    local delta = calculate_delta(resolved_yaw, original_yaw)
    
    print(string.format("[Resolver] %s | %.1f° → %.1f° | Correction: %.1f°",
        player_name,
        original_yaw,
        resolved_yaw,
        delta
    ))
end

-- =====================================
-- INITIALIZATION
-- =====================================
local function init()
    init_interfaces()
    
    callbacks.add(e_callbacks.SETUP_COMMAND, on_create_move)
    callbacks.add(e_callbacks.PAINT, on_paint)
    
    print("[Resolver] Initialized successfully")
end

init()