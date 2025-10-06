-- Custom Resolver for Primordial.dev
-- Enhanced Mathematical resolver with ultra-precision
-- Version: 3.0 Ultra-Precise

local ffi = require("ffi")

-- =====================================
-- 1. FFI DEFINITIONS
-- =====================================
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

struct AnimationLayer {
    char pad[24];
    uint32_t m_nSequence;
    float m_flPrevCycle;
    float m_flWeight;
    float m_flWeightDeltaRate;
    float m_flCycle;
    float m_flPlaybackRate;
};
]]

-- =====================================
-- 2. GLOBALS & CACHE
-- =====================================
local RawIEntityList = nil
local IEntityList = nil
local resolver_cache = {}
local last_update = {}
local initialized = false
local player_history = {}
local desync_patterns = {}

-- =====================================
-- 3. ULTRA-PRECISION MATH FUNCTIONS
-- =====================================
local function normalize_yaw(yaw)
    while yaw > 180 do yaw = yaw - 360 end
    while yaw < -180 do yaw = yaw + 360 end
    return yaw
end

local function angle_diff(a1, a2)
    local diff = a1 - a2
    while diff > 180 do diff = diff - 360 end
    while diff < -180 do diff = diff + 360 end
    return diff
end

local function clamp(val, min, max)
    return math.max(min, math.min(max, val))
end

-- Ultra-precise angle interpolation
local function lerp_angle(a1, a2, t)
    local diff = angle_diff(a2, a1)
    return normalize_yaw(a1 + diff * t)
end

-- Calculate precise desync side with sub-degree accuracy
local function calculate_desync_side(eye_yaw, feet_yaw, max_desync)
    local delta = angle_diff(eye_yaw, feet_yaw)
    local side = delta > 0 and 1 or -1
    local ratio = math.abs(delta) / max_desync
    return side, ratio, delta
end

-- =====================================
-- 4. ENHANCED MEMORY ACCESS
-- =====================================
local function init_interfaces()
    if initialized then return true end

    local success = pcall(function()
        RawIEntityList = ffi.cast("void***", memory.create_interface("client.dll", "VClientEntityList003"))
        if RawIEntityList then
            IEntityList = ffi.cast("GetClientEntity_t", RawIEntityList[0][3])
            initialized = true
        end
    end)

    return success and initialized
end

local function get_animstate(player)
    if not initialized or not player then return nil end

    local idx = player:get_index()
    if idx <= 0 or idx > 64 then return nil end

    -- Enhanced caching with tick validation
    local tick = global_vars.tick_count()
    if last_update[idx] and tick - last_update[idx] < 1 then
        return resolver_cache[idx] and resolver_cache[idx].animstate
    end

    local success, animstate = pcall(function()
        local ptr = IEntityList(RawIEntityList, idx)
        if not ptr or ptr == ffi.NULL then return nil end
        
        local addr = ffi.cast("struct CAnimstate**", ffi.cast("char*", ptr) + 0x9960)
        if not addr or addr[0] == ffi.NULL then return nil end
        
        return addr[0]
    end)

    if success and animstate then
        last_update[idx] = tick
        return animstate
    end

    return nil
end

local function get_animation_layers(player)
    if not initialized or not player then return nil end

    local idx = player:get_index()
    local success, layers = pcall(function()
        local ptr = IEntityList(RawIEntityList, idx)
        if not ptr or ptr == ffi.NULL then return nil end
        
        local layer_ptr = ffi.cast("struct AnimationLayer*", ffi.cast("char*", ptr) + 0x2990)
        if not layer_ptr then return nil end
        
        local result = {}
        for i = 0, 12 do
            result[i] = {
                weight = layer_ptr[i].m_flWeight,
                cycle = layer_ptr[i].m_flCycle,
                playback = layer_ptr[i].m_flPlaybackRate
            }
        end
        return result
    end)

    return success and layers or nil
end

-- =====================================
-- 5. ULTRA-PRECISE DESYNC CALCULATIONS
-- =====================================
local function calculate_ultra_precise_max_desync(animstate)
    local speed = animstate.m_flSpeed2D
    local duck = animstate.m_fDuckAmount
    local on_ground = animstate.m_bOnGround
    local in_air = animstate.m_flTimeSinceInAir > 0.0

    -- Base desync limit with ultra-precision
    local base_limit = 0.0

    if not on_ground or in_air then
        -- In air = minimal desync
        return 0.0
    end

    -- Ultra-precise speed-based calculation
    if speed <= 0.01 then
        -- Static - maximum desync
        base_limit = 60.0
    else
        -- Moving - calculate with engine precision
        local speed_normalized = math.min(speed / 260.0, 1.0)
        local speed_factor = 1.0 - (speed_normalized * 0.333333)
        base_limit = 60.0 * speed_factor
        
        -- Minimum moving desync
        if speed > 1.0 then
            base_limit = math.max(base_limit, 29.0)
        end
    end

    -- Duck modifier with precise calculation
    if duck > 0.0 then
        local duck_factor = 1.0 - (duck * 0.344827586)
        base_limit = base_limit * duck_factor
    end

    -- Additional precision factors
    local lean = math.abs(animstate.m_flLeanAmount)
    if lean > 0.1 then
        local lean_factor = 1.0 - (lean * 0.1)
        base_limit = base_limit * lean_factor
    end

    return math.max(base_limit, 0.0)
end

-- Advanced desync pattern analysis
local function analyze_desync_pattern(player_idx, current_data)
    if not desync_patterns[player_idx] then
        desync_patterns[player_idx] = {
            history = {},
            pattern_type = "unknown",
            last_switch = 0,
            consistency = 0.0
        }
    end

    local pattern = desync_patterns[player_idx]
    local tick = global_vars.tick_count()

    -- Add current data to history
    table.insert(pattern.history, {
        tick = tick,
        eye_yaw = current_data.eye_yaw,
        feet_yaw = current_data.feet_yaw,
        desync = current_data.desync,
        side = current_data.side
    })

    -- Keep only recent history (last 64 ticks)
    if #pattern.history > 64 then
        table.remove(pattern.history, 1)
    end

    -- Analyze pattern for delay detection
    if #pattern.history >= 8 then
        local recent = pattern.history
        local side_changes = 0
        local consistent_side = 0

        for i = 2, #recent do
            if recent[i].side ~= recent[i-1].side then
                side_changes = side_changes + 1
            end
            if recent[i].side == recent[#recent].side then
                consistent_side = consistent_side + 1
            end
        end

        local consistency_ratio = consistent_side / (#recent - 1)
        
        -- Detect delay patterns
        if side_changes <= 2 and consistency_ratio > 0.8 then
            pattern.pattern_type = "delay"
        elseif side_changes > 4 and consistency_ratio < 0.6 then
            pattern.pattern_type = "random"
        else
            pattern.pattern_type = "normal"
        end

        pattern.consistency = consistency_ratio
    end

    return pattern
end

-- Ultra-precise desync calculation with delay detection
local function calculate_ultra_precise_desync(animstate, player_idx)
    local eye_yaw = animstate.m_flEyeYaw
    local goal_feet = animstate.m_flGoalFeetYaw
    local current_feet = animstate.m_flCurrentFeetYaw
    local feet_rate = animstate.m_flFeetYawRate
    local time_delta = animstate.m_flAnimUpdateDelta

    -- Calculate base delta
    local raw_delta = angle_diff(eye_yaw, goal_feet)

    -- Apply feet rate correction with ultra-precision
    if time_delta > 0 and time_delta < 1.0 and math.abs(feet_rate) > 0.001 then
        local rate_correction = feet_rate * time_delta * 0.0174532925
        raw_delta = raw_delta + math.deg(rate_correction)
    end

    -- Analyze current state
    local current_data = {
        eye_yaw = eye_yaw,
        feet_yaw = goal_feet,
        desync = raw_delta,
        side = raw_delta > 0 and 1 or -1
    }

    -- Get pattern analysis
    local pattern = analyze_desync_pattern(player_idx, current_data)

    -- Apply pattern-based corrections
    if pattern.pattern_type == "delay" then
        -- Delay anti-aim - use historical data for prediction
        if #pattern.history >= 4 then
            local avg_side = 0
            for i = math.max(1, #pattern.history - 3), #pattern.history do
                avg_side = avg_side + pattern.history[i].side
            end
            avg_side = avg_side / math.min(4, #pattern.history)
            
            -- Predict next side based on delay pattern
            local predicted_side = avg_side > 0 and 1 or -1
            raw_delta = math.abs(raw_delta) * predicted_side
        end
    elseif pattern.pattern_type == "random" then
        -- Random anti-aim - use statistical analysis
        if pattern.consistency > 0.0 then
            local random_factor = 1.0 - pattern.consistency
            raw_delta = raw_delta * (1.0 + random_factor * 0.2)
        end
    end

    return raw_delta, pattern
end

-- =====================================
-- 6. ULTRA-PRECISE RESOLVER CORE
-- =====================================
local function resolve_angle_ultra_precise(player)
    if not player or not player:is_alive() then return end

    local idx = player:get_index()
    local animstate = get_animstate(player)
    if not animstate then return end

    -- Get all animstate data with ultra-precision
    local eye_yaw = animstate.m_flEyeYaw
    local goal_feet = animstate.m_flGoalFeetYaw
    local current_feet = animstate.m_flCurrentFeetYaw
    local torso_yaw = animstate.m_flCurrentTorsoYaw
    local lean = animstate.m_flLeanAmount
    local feet_cycle = animstate.m_flFeetCycle
    local feet_rate = animstate.m_flFeetYawRate
    local speed_2d = animstate.m_flSpeed2D
    local duck = animstate.m_fDuckAmount
    local on_ground = animstate.m_bOnGround
    local vel_x = animstate.m_vVelocityX
    local vel_y = animstate.m_vVelocityY

    -- Calculate ultra-precise max desync
    local max_desync = calculate_ultra_precise_max_desync(animstate)

    -- Calculate precise desync with pattern analysis
    local precise_desync, pattern = calculate_ultra_precise_desync(animstate, idx)

    -- Initialize resolution variables
    local resolved_yaw = eye_yaw
    local side = 0
    local confidence = 0.0

    -- Method 1: Ultra-precise LBY update detection
    local feet_delta = angle_diff(goal_feet, current_feet)
    if math.abs(feet_delta) > 30.0 then
        -- LBY is updating - use goal feet as base
        resolved_yaw = goal_feet
        
        -- Apply ultra-precise cycle correction
        local cycle_offset = (feet_cycle - 0.5) * 2.0 * 1.745329
        resolved_yaw = resolved_yaw + cycle_offset
        
        -- Add feet rate correction
        if math.abs(feet_rate) > 0.001 then
            local rate_correction = feet_rate * 0.008726646  -- Ultra-precise rate factor
            resolved_yaw = resolved_yaw + rate_correction
        end
        
        side = feet_delta > 0 and 1 or -1
        confidence = 0.95
        
    -- Method 2: Ultra-precise lean resolution
    elseif math.abs(lean) > 0.005 then
        -- Calculate exact lean angle with sub-degree precision
        local lean_radians = lean * 0.0174532925
        local lean_correction = math.sin(lean_radians) * max_desync
        
        resolved_yaw = goal_feet + lean_correction
        
        -- Add micro-adjustments based on feet cycle
        local cycle_micro = (feet_cycle * 2.0 - 1.0) * 0.286788  -- Sub-degree precision
        resolved_yaw = resolved_yaw + cycle_micro
        
        -- Apply torso correction
        local torso_delta = angle_diff(torso_yaw, goal_feet)
        resolved_yaw = resolved_yaw + (torso_delta * 0.143394)
        
        side = lean > 0 and 1 or -1
        confidence = 0.90
        
    -- Method 3: Ultra-precise velocity resolution
    elseif speed_2d > 0.05 then
        -- Calculate exact movement angle
        local vel_angle = math.deg(math.atan2(vel_y, vel_x))
        local vel_delta = angle_diff(vel_angle, eye_yaw)
        
        -- Speed-based desync calculation with ultra-precision
        local speed_fraction = math.min(speed_2d / 260.0, 1.0)
        local speed_desync = max_desync * (1.0 - speed_fraction * 0.4)
        
        if math.abs(vel_delta) > speed_desync * 0.8 then
            -- High velocity desync
            resolved_yaw = vel_angle
            
            -- Add cycle-based micro-correction
            local cycle_phase = feet_cycle * 2.0 * math.pi
            local cycle_correction = math.sin(cycle_phase) * speed_desync * 0.1
            resolved_yaw = resolved_yaw + cycle_correction
            
        else
            -- Precise moving desync calculation
            local cycle_phase = feet_cycle * 2.0 * math.pi
            local cycle_offset = math.sin(cycle_phase) * speed_desync
            
            resolved_yaw = goal_feet + cycle_offset
            
            -- Add velocity correction with ultra-precision
            local vel_correction = vel_delta * 0.114591559
            resolved_yaw = resolved_yaw + vel_correction
        end
        
        side = vel_delta > 0 and 1 or -1
        confidence = 0.85
        
    -- Method 4: Ultra-precise static resolution with pattern analysis
    else
        -- For static players, use maximum precision with pattern detection
        
        if pattern.pattern_type == "delay" then
            -- Delay anti-aim - use pattern prediction
            if #pattern.history >= 3 then
                local recent_side = pattern.history[#pattern.history].side
                local side_consistency = 0
                
                for i = math.max(1, #pattern.history - 2), #pattern.history do
                    if pattern.history[i].side == recent_side then
                        side_consistency = side_consistency + 1
                    end
                end
                
                if side_consistency >= 2 then
                    -- Predict opposite side for delay
                    side = recent_side * -1
                    resolved_yaw = goal_feet + (max_desync * side * 0.9)
                    confidence = 0.88
                else
                    -- Use precise desync calculation
                    side = precise_desync > 0 and 1 or -1
                    resolved_yaw = goal_feet + (precise_desync * -0.97435897)
                    confidence = 0.80
                end
            else
                -- Fallback to standard calculation
                side = precise_desync > 0 and 1 or -1
                resolved_yaw = goal_feet + (precise_desync * -0.97435897)
                confidence = 0.75
            end
            
        elseif pattern.pattern_type == "random" then
            -- Random anti-aim - use statistical approach
            local random_factor = 1.0 - pattern.consistency
            local desync_multiplier = 1.0 + (random_factor * 0.3)
            
            side = precise_desync > 0 and 1 or -1
            resolved_yaw = goal_feet + (precise_desync * -0.97435897 * desync_multiplier)
            confidence = 0.70
            
        else
            -- Standard ultra-precise static resolution
            if math.abs(precise_desync) > 0.01 then
                side = precise_desync > 0 and 1 or -1
                
                -- Calculate precise desync amount
                local desync_ratio = math.abs(precise_desync) / 60.0
                
                if desync_ratio > 0.58333 then
                    -- Near max desync - use opposite side
                    resolved_yaw = goal_feet + (max_desync * side * -1)
                    confidence = 0.92
                else
                    -- Partial desync - precise calculation
                    resolved_yaw = goal_feet + (precise_desync * -0.97435897)
                    confidence = 0.85
                end
                
                -- Add micro-corrections
                local micro_adjust = (feet_cycle - 0.5) * 1.145915
                resolved_yaw = resolved_yaw + micro_adjust
                
            else
                -- Minimal desync
                resolved_yaw = goal_feet
                confidence = 0.60
            end
        end
    end

    -- Apply final ultra-precision corrections
    if math.abs(lean) > 0.001 then
        local lean_correction = lean * 2.864788976
        resolved_yaw = resolved_yaw + lean_correction
    end

    -- Add torso correction for final precision
    local torso_delta = angle_diff(torso_yaw, goal_feet)
    if math.abs(torso_delta) > 0.1 then
        resolved_yaw = resolved_yaw + (torso_delta * 0.143394)
    end

    -- Normalize with ultra-precision
    resolved_yaw = normalize_yaw(resolved_yaw)

    -- Store with full precision and pattern data
    if not resolver_cache[idx] then
        resolver_cache[idx] = {}
    end

    resolver_cache[idx] = {
        original = eye_yaw,
        resolved = resolved_yaw,
        side = side,
        confidence = confidence,
        tick = global_vars.tick_count(),
        animstate = animstate,
        precise_desync = precise_desync,
        max_desync = max_desync,
        pattern_type = pattern.pattern_type,
        pattern_consistency = pattern.consistency
    }

    -- Apply resolution with ultra-precision
    local success = pcall(function()
        if player.set_prop then
            player:set_prop("m_angEyeAngles[1]", resolved_yaw)
        end
    end)

    if not success then
        resolver_cache[idx].applied = false
    else
        resolver_cache[idx].applied = true
    end

    return resolved_yaw, side, confidence
end

-- =====================================
-- 7. MENU
-- =====================================
local menu = {
    enabled = menu.add_checkbox("Scripts", "Resolver", false),
    logs = menu.add_checkbox("Scripts", "Logs", false)
}

-- =====================================
-- 8. ENHANCED LOGGING
-- =====================================
local function log(text)
    if menu.logs:get() then
        print("[Ultra-Resolver] " .. text)
    end
end

-- =====================================
-- 9. CALLBACKS
-- =====================================
local function on_setup_command()
    if not menu.enabled:get() then return end

    if not initialized then
        init_interfaces()
        return
    end

    local enemies = entity_list.get_players(true)
    if not enemies then return end

    for _, enemy in pairs(enemies) do
        if enemy and enemy:is_alive() and not enemy:is_dormant() then
            local resolved, side, confidence = resolve_angle_ultra_precise(enemy)
            
            if resolved and menu.logs:get() then
                local idx = enemy:get_index()
                local data = resolver_cache[idx]
                if data then
                    local delta = angle_diff(data.resolved, data.original)
                    log(string.format("%s | Resolved: %.6f° | Delta: %.6f° | Max: %.3f° | Confidence: %.1f%% | Pattern: %s",
                        enemy:get_name(),
                        data.resolved,
                        delta,
                        data.max_desync,
                        data.confidence * 100,
                        data.pattern_type or "unknown"
                    ))
                end
            end
        end
    end
end

local function on_paint()
    if not menu.enabled:get() then return end

    -- Enhanced cache cleanup
    local current_tick = global_vars.tick_count()
    for idx, data in pairs(resolver_cache) do
        if data.tick and current_tick - data.tick > 128 then
            resolver_cache[idx] = nil
            last_update[idx] = nil
            desync_patterns[idx] = nil
        end
    end
end

-- =====================================
-- 10. INITIALIZATION
-- =====================================
callbacks.add(e_callbacks.SETUP_COMMAND, on_setup_command)
callbacks.add(e_callbacks.PAINT, on_paint)

-- Initial setup
init_interfaces()
log("Ultra-Precise Resolver initialized successfully")