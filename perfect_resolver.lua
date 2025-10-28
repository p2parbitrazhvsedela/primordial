--[[
    Perfect Resolver v7.0 - OPTIMIZED YAW CORRECTION
    Maximum accuracy with minimal complexity
    No ML, No patterns - PURE GEOMETRIC MATHEMATICS
    
    v7.0 CORE PRINCIPLE:
    "Jitter AA shows fake yaw on one side, real body is on OPPOSITE side"
    
    FORMULA (all cases):
    ═══════════════════════════════════════════════════════════
    1. Base correction = abs_desync (the actual body angle offset)
    2. Direction = OPPOSITE to current desync side
       correction = (desync > 0) ? -abs_desync : +abs_desync
    
    3. LEAN adjustment (MOST IMPORTANT):
       correction += lean × coefficient
       - Standing: ×35
       - Moving: ×40
       Lean shows REAL body lean direction (±1.0 range)
    
    4. FEET YAW RATE (rotation speed):
       correction += feet_yaw_rate × coefficient
       - Standing: ×0.15
       - Moving: ×0.16
       Shows body turning speed and direction
    
    5. MOVEMENT DIRECTION (moving only):
       move_angle = atan2(move_y, move_x)
       move_delta = normalize(move_angle - eye_yaw)
       correction += move_delta × 0.10
       Body follows movement direction
    
    6. JITTER STRENGTH boost:
       strength = |yaw_velocity| / 100
       correction *= (1.0 + strength × 0.10-0.12)
       Stronger jitter = more aggressive correction
    
    Clamp: 70° (max realistic with adjustments)
    ═══════════════════════════════════════════════════════════
    
    v6.7: Fakelag | v6.5: Math | v6.4: Delay
]]

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
]]

local RawIEntityList = ffi.cast("void***", memory.create_interface("client.dll", "VClientEntityList003"))
local IEntityList = ffi.cast("GetClientEntity_t", RawIEntityList[0][3])

local function GetEntity(index)
    return IEntityList(RawIEntityList, index)
end

-- Config
local cfg_enable = menu.add_checkbox("Perfect Resolver", "Enable Resolver", false)
local cfg_logs = menu.add_checkbox("Perfect Resolver", "Debug Logs", false)

-- Player data storage
local player_data = {}
for i = 1, 65 do
    player_data[i] = {
        -- History tracking (last 4 ticks)
        history = {},
        
        -- Jitter metrics
        jitter_detected = false,
        jitter_amplitude = 0,
        jitter_frequency = 0,
        
        -- Advanced math tracking
        yaw_velocity = 0,        -- First derivative (dy/dt)
        yaw_acceleration = 0,    -- Second derivative (d²y/dt²)
        jitter_phase = 0,        -- Phase angle of jitter wave
        harmonic_period = 0,     -- Period of oscillation
        jitter_intensity = 0,    -- Overall jitter strength (0-1)
        consecutive_high_vel = 0, -- Consecutive high velocity ticks
        
        -- Side tracking
        current_side = 0,
        last_side = 0,
        side_flips = 0,
        
        -- State tracking
        was_standing = false,
        last_speed = 0,
        
        -- Timing
        last_update = 0,
        
        -- Delay anti-aim tracking
        last_real_yaw = 0,
        last_yaw_update_tick = 0,
        ticks_since_update = 0,
        delay_detected = false,
        delay_interval = 0,
        frozen_ticks = 0,
        delay_history = {},
        delay_confidence = 0,
        last_delay_side = 0,
        
        -- Fakelag / Lagcomp tracking
        last_simulation_time = 0,
        choke_amount = 0,
        avg_choke = 0,
        fakelag_detected = false,
        breaklag_detected = false,
        velocity_history = {},
        last_origin = nil,
        extrapolated_yaw = 0
    }
end

-- Normalize angle
local function normalize_angle(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

-- Get animstate safely
local function get_animstate(player)
    local ok, result = pcall(function()
        local ptr = GetEntity(player:get_index())
        if not ptr then return nil end
        return ffi.cast("struct CAnimstate**", ptr + 0x9960)[0]
    end)
    return ok and result or nil
end

-- Calculate velocity angle
local function get_velocity_angle(vel_x, vel_y)
    if vel_x == 0 and vel_y == 0 then return 0 end
    return math.deg(math.atan2(vel_y, vel_x))
end

-- Calculate 3D vector angle
local function vector_to_angle(vec_x, vec_y)
    if vec_x == 0 and vec_y == 0 then return 0 end
    local yaw = math.deg(math.atan2(vec_y, vec_x))
    return normalize_angle(yaw)
end

-- Get player head position
local function get_head_position(player)
    local ok, result = pcall(function()
        local origin = player:get_prop("m_vecOrigin")
        if not origin then return nil end
        
        local view_offset = player:get_prop("m_vecViewOffset")
        if not view_offset then
            view_offset = {x = 0, y = 0, z = 64}  -- Default head height
        end
        
        return {
            x = origin.x + view_offset.x,
            y = origin.y + view_offset.y,
            z = origin.z + view_offset.z
        }
    end)
    
    return ok and result or nil
end

-- Calculate angle to position
local function calc_angle_to_pos(from_pos, to_pos)
    if not from_pos or not to_pos then return 0 end
    
    local delta_x = to_pos.x - from_pos.x
    local delta_y = to_pos.y - from_pos.y
    
    return vector_to_angle(delta_x, delta_y)
end

-- Main resolver function
local function resolve_player(player)
    if not player or player:is_dormant() then return end
    
    local player_index = player:get_index()
    local data = player_data[player_index]
    
    -- Get animstate
    local animstate = get_animstate(player)
    if not animstate then return end
    
    -- Read all animstate data
    local eye_yaw = animstate.m_flEyeYaw
    local goal_feet_yaw = animstate.m_flGoalFeetYaw
    local current_feet_yaw = animstate.m_flCurrentFeetYaw
    local speed = animstate.m_flSpeed2D
    local lean = animstate.m_flLeanAmount
    local duck = animstate.m_fDuckAmount
    local feet_yaw_rate = animstate.m_flFeetYawRate or 0
    local time_stopped = animstate.m_flTimeSinceStoppedMoving or 0
    local time_started = animstate.m_flTimeSinceStartedMoving or 0
    local vel_x = animstate.m_vVelocityX or 0
    local vel_y = animstate.m_vVelocityY or 0
    local on_ground = animstate.m_bOnGround
    
    -- Calculate desync
    local desync = normalize_angle(eye_yaw - goal_feet_yaw)
    local abs_desync = math.abs(desync)
    
    -- Calculate velocity angle and delta
    local vel_angle = get_velocity_angle(vel_x, vel_y)
    local vel_delta = normalize_angle(eye_yaw - vel_angle)
    
    -- Get 3D position data
    local enemy_head = get_head_position(player)
    local local_player = entity_list.get_local_player()
    local local_head = local_player and get_head_position(local_player) or nil
    
    -- Calculate real angle enemy should be looking at us
    local real_angle_to_local = 0
    local angle_difference = 0
    if enemy_head and local_head then
        real_angle_to_local = calc_angle_to_pos(enemy_head, local_head)
        angle_difference = math.abs(normalize_angle(eye_yaw - real_angle_to_local))
    end
    
    -- Origin position from animstate (more accurate)
    local origin_x = animstate.m_vOriginX
    local origin_y = animstate.m_vOriginY
    local last_origin_x = animstate.m_vLastOriginX
    local last_origin_y = animstate.m_vLastOriginY
    
    -- Movement vector from origin delta
    local move_x = origin_x - last_origin_x
    local move_y = origin_y - last_origin_y
    local move_angle = get_velocity_angle(move_x, move_y)
    local move_delta = normalize_angle(eye_yaw - move_angle)
    
    -- Store current tick data
    local current_tick = {
        eye_yaw = eye_yaw,
        desync = desync,
        abs_desync = abs_desync,
        speed = speed,
        lean = lean,
        duck = duck,
        feet_rate = feet_yaw_rate,
        vel_delta = vel_delta,
        time = global_vars.cur_time()
    }
    
    table.insert(data.history, current_tick)
    
    -- Keep last 4 ticks
    if #data.history > 4 then
        table.remove(data.history, 1)
    end
    
    -- Need at least 3 ticks for analysis
    if #data.history < 3 then return end
    
    local curr = data.history[#data.history]
    local prev = data.history[#data.history - 1]
    local prev2 = data.history[#data.history - 2]
    
    -- ===== FAKELAG / LAGCOMP DETECTION =====
    
    local current_tick = global_vars.tick_count()
    local simulation_time = player:get_prop("m_flSimulationTime")
    
    -- Calculate choke (missed ticks)
    if data.last_simulation_time > 0 and simulation_time > data.last_simulation_time then
        local sim_delta = simulation_time - data.last_simulation_time
        local tick_interval = global_vars.interval_per_tick()
        local ticks_elapsed = math.floor(sim_delta / tick_interval + 0.5)
        
        -- Choke = ticks elapsed - 1 (normal is 1 tick per update)
        data.choke_amount = math.max(0, ticks_elapsed - 1)
        
        -- Update average choke with EMA
        if data.avg_choke == 0 then
            data.avg_choke = data.choke_amount
        else
            data.avg_choke = (data.avg_choke * 0.8) + (data.choke_amount * 0.2)
        end
        
        -- Fakelag detection (consistent choking)
        if data.choke_amount >= 2 or data.avg_choke > 1.5 then
            data.fakelag_detected = true
        else
            data.fakelag_detected = false
        end
        
        -- Breaklag detection (sudden release after choking)
        if data.choke_amount >= 4 then
            data.breaklag_detected = true
        else
            data.breaklag_detected = false
        end
    end
    
    data.last_simulation_time = simulation_time
    
    -- Velocity-based extrapolation for fakelag
    local origin = player:get_prop("m_vecOrigin")
    if origin and data.last_origin then
        local velocity_x = (origin.x - data.last_origin.x) / (data.choke_amount + 1)
        local velocity_y = (origin.y - data.last_origin.y) / (data.choke_amount + 1)
        
        -- Store velocity history
        table.insert(data.velocity_history, {x = velocity_x, y = velocity_y})
        if #data.velocity_history > 5 then
            table.remove(data.velocity_history, 1)
        end
        
        -- Calculate average velocity for prediction
        if #data.velocity_history >= 2 then
            local avg_vel_x = 0
            local avg_vel_y = 0
            for _, vel in ipairs(data.velocity_history) do
                avg_vel_x = avg_vel_x + vel.x
                avg_vel_y = avg_vel_y + vel.y
            end
            avg_vel_x = avg_vel_x / #data.velocity_history
            avg_vel_y = avg_vel_y / #data.velocity_history
            
            -- Extrapolate yaw based on velocity direction
            if math.abs(avg_vel_x) > 0.5 or math.abs(avg_vel_y) > 0.5 then
                data.extrapolated_yaw = math.deg(math.atan2(avg_vel_y, avg_vel_x))
            end
        end
    end
    data.last_origin = origin
    
    -- ===== DELAY ANTI-AIM DETECTION =====
    
    -- Detect if yaw actually updated this tick
    local yaw_delta_from_last = math.abs(eye_yaw - data.last_real_yaw)
    local yaw_actually_updated = yaw_delta_from_last > 1.0  -- Threshold for real update
    
    if yaw_actually_updated then
        -- Real update detected
        local ticks_since_last_update = current_tick - data.last_yaw_update_tick
        
        if data.last_yaw_update_tick > 0 and ticks_since_last_update > 0 then
            -- Store in history for accurate interval calculation
            table.insert(data.delay_history, ticks_since_last_update)
            if #data.delay_history > 8 then
                table.remove(data.delay_history, 1)
            end
            
            -- Calculate median interval (more robust than EMA)
            if #data.delay_history >= 3 then
                local sorted = {}
                for i, v in ipairs(data.delay_history) do
                    sorted[i] = v
                end
                table.sort(sorted)
                local median_idx = math.ceil(#sorted / 2)
                data.delay_interval = sorted[median_idx]
                
                -- Confidence based on consistency
                local consistency = 0
                for _, v in ipairs(data.delay_history) do
                    if math.abs(v - data.delay_interval) <= 1 then
                        consistency = consistency + 1
                    end
                end
                data.delay_confidence = consistency / #data.delay_history
            else
                data.delay_interval = ticks_since_last_update
                data.delay_confidence = 0.5
            end
            
            -- Detect delay pattern (updates every N ticks)
            if ticks_since_last_update >= 2 then
                data.delay_detected = true
            end
            
            -- Track which side they went to
            data.last_delay_side = desync > 0 and 1 or -1
        end
        
        data.last_real_yaw = eye_yaw
        data.last_yaw_update_tick = current_tick
        data.ticks_since_update = 0
        data.frozen_ticks = 0
    else
        -- Yaw is frozen (no update)
        data.ticks_since_update = data.ticks_since_update + 1
        data.frozen_ticks = data.frozen_ticks + 1
        
        -- If frozen for 2+ ticks, likely delay AA
        if data.frozen_ticks >= 2 then
            data.delay_detected = true
        end
    end
    
    -- ===== JITTER DETECTION =====
    
    -- Calculate yaw changes
    local yaw_change = math.abs(curr.eye_yaw - prev.eye_yaw)
    local yaw_change_prev = math.abs(prev.eye_yaw - prev2.eye_yaw)
    
    -- Calculate desync changes
    local desync_change = math.abs(curr.abs_desync - prev.abs_desync)
    
    -- Detect side flips
    local side_flip = (curr.desync * prev.desync) < 0
    local double_flip = side_flip and (prev.desync * prev2.desync) < 0
    
    -- Calculate jitter metrics
    local max_yaw_change = math.max(yaw_change, yaw_change_prev)
    local avg_yaw_change = (yaw_change + yaw_change_prev) / 2
    
    -- ===== ADVANCED MATH: DERIVATIVES & HARMONIC ANALYSIS =====
    
    -- Calculate yaw velocity (first derivative: dy/dt)
    local dt = 1  -- tick interval
    local new_velocity = yaw_change / dt
    
    -- Calculate yaw acceleration (second derivative: d²y/dt²)
    local prev_velocity = data.yaw_velocity
    data.yaw_velocity = new_velocity
    data.yaw_acceleration = (new_velocity - prev_velocity) / dt
    
    -- Harmonic analysis: detect oscillation period
    if side_flip then
        if data.harmonic_period == 0 then
            data.harmonic_period = 2  -- Started oscillating
        end
    else
        if data.harmonic_period > 0 and data.harmonic_period < 10 then
            data.harmonic_period = data.harmonic_period + 1
        end
    end
    
    -- Phase angle estimation (0 to 2π) based on desync position
    -- Assuming jitter oscillates like: desync = A * sin(ωt + φ)
    if abs_desync > 5 then
        local normalized_desync = desync / 60  -- Normalize to -1 to 1
        local phase_estimate = math.asin(math.max(-1, math.min(1, normalized_desync)))
        data.jitter_phase = phase_estimate
    end
    
    -- Update jitter metrics
    data.jitter_amplitude = max_yaw_change
    
    -- Calculate jitter intensity (0-1 scale)
    local intensity_factors = 0
    local intensity_count = 0
    
    if yaw_change > 25 then intensity_factors = intensity_factors + 1; intensity_count = intensity_count + 1 end
    if math.abs(data.yaw_velocity) > 30 then intensity_factors = intensity_factors + 1 end
    intensity_count = intensity_count + 1
    if math.abs(data.yaw_acceleration) > 40 then intensity_factors = intensity_factors + 1 end
    intensity_count = intensity_count + 1
    if side_flip then intensity_factors = intensity_factors + 1 end
    intensity_count = intensity_count + 1
    if desync_change > 25 then intensity_factors = intensity_factors + 1 end
    intensity_count = intensity_count + 1
    
    data.jitter_intensity = intensity_factors / intensity_count
    
    -- Track consecutive high velocity
    if math.abs(data.yaw_velocity) > 35 then
        data.consecutive_high_vel = data.consecutive_high_vel + 1
    else
        data.consecutive_high_vel = 0
    end
    
    -- Enhanced jitter detection with derivatives
    local is_jittering = 
        (yaw_change > 25) or                           -- Large yaw change
        (yaw_change > 18 and side_flip) or            -- Medium change with flip
        (double_flip) or                               -- Double side flip
        (desync_change > 25) or                       -- Large desync change
        (yaw_change > 15 and yaw_change_prev > 15) or -- Consistent changes
        (math.abs(data.yaw_acceleration) > 40) or     -- High acceleration
        (data.consecutive_high_vel >= 2)              -- Sustained high velocity
    
    data.jitter_detected = is_jittering
    
    -- Track side flips
    local current_side = desync > 0 and 1 or -1
    if current_side ~= data.last_side and data.last_side ~= 0 then
        data.side_flips = data.side_flips + 1
    end
    data.current_side = current_side
    data.last_side = current_side
    
    -- ===== STATE DETECTION =====
    
    local is_standing = speed < 5
    local is_slowwalking = speed >= 5 and speed < 80
    local is_walking = speed >= 80 and speed < 150
    local is_running = speed >= 150
    local is_crouching = duck > 0.5
    local is_in_air = not on_ground
    
    -- ===== CORRECTION CALCULATION =====
    
    local correction = 0
    local mode = "IDLE"
    local details = {}
    
    -- ===== FAKELAG / LAGCOMP HANDLING =====
    if data.fakelag_detected then
        mode = "FAKELAG"
        
        -- Choke-based correction multiplier
        local choke_mult = 1.0 + (data.choke_amount * 0.05)  -- +5% per choked tick
        choke_mult = math.min(choke_mult, 1.30)  -- Max 1.3x
        
        if data.breaklag_detected then
            -- Breaklag (4+ choked ticks) - VERY aggressive
            mode = "BREAKLAG"
            
            if abs_desync > 35 then
                -- High desync with breaklag
                local base = math.min(abs_desync * 1.05, 60)  -- More aggressive
                correction = (desync > 0 and -base or base) * choke_mult
                
                -- Velocity extrapolation correction
                if data.extrapolated_yaw ~= 0 then
                    local extrap_delta = normalize_angle(data.extrapolated_yaw - eye_yaw)
                    if math.abs(extrap_delta) > 45 then
                        -- Velocity direction strongly disagrees with yaw
                        local vel_boost = math.min(math.abs(extrap_delta) * 0.15, 12)
                        correction = correction + (extrap_delta > 0 and vel_boost or -vel_boost)
                        table.insert(details, string.format("vel_extrap_%.0f", vel_boost))
                    end
                end
                
                -- Lean (critical for breaklag)
                if math.abs(lean) > 0.35 then
                    correction = correction + (lean > 0 and 18 or -18)
                    table.insert(details, "lean_brk")
                elseif math.abs(lean) > 0.2 then
                    correction = correction + (lean > 0 and 12 or -12)
                end
                
                table.insert(details, string.format("choke_%d", data.choke_amount))
            else
                -- Medium/low desync breaklag
                correction = (desync > 0 and -(abs_desync * 0.95) or (abs_desync * 0.95)) * choke_mult
            end
            
            table.insert(details, string.format("brk_x%.2f", choke_mult))
            
        else
            -- Regular fakelag (2-3 choked ticks)
            
            if abs_desync > 35 then
                -- High desync fakelag
                local base = math.min(abs_desync * 1.00, 60)
                correction = (desync > 0 and -base or base) * choke_mult
                
                -- Velocity consideration
                if data.extrapolated_yaw ~= 0 then
                    local extrap_delta = normalize_angle(data.extrapolated_yaw - eye_yaw)
                    if math.abs(extrap_delta) > 60 then
                        local vel_boost = math.min(math.abs(extrap_delta) * 0.12, 8)
                        correction = correction + (extrap_delta > 0 and vel_boost or -vel_boost)
                        table.insert(details, "vel_adj")
                    end
                end
                
                -- Lean
                if math.abs(lean) > 0.3 then
                    correction = correction + (lean > 0 and 15 or -15)
                    table.insert(details, "lean_fl")
                elseif math.abs(lean) > 0.18 then
                    correction = correction + (lean > 0 and 10 or -10)
                end
                
                -- Feet yaw rate (important for fakelag)
                if math.abs(feet_yaw_rate) > 50 then
                    correction = correction + (feet_yaw_rate > 0 and 8 or -8)
                    table.insert(details, "feet_fl")
                elseif math.abs(feet_yaw_rate) > 30 then
                    correction = correction + (feet_yaw_rate > 0 and 5 or -5)
                end
                
                table.insert(details, string.format("choke_%d", data.choke_amount))
            else
                -- Medium/low desync fakelag
                correction = (desync > 0 and -(abs_desync * 0.92) or (abs_desync * 0.92)) * choke_mult
                
                if math.abs(lean) > 0.25 then
                    correction = correction + (lean > 0 and 9 or -9)
                end
            end
            
            table.insert(details, string.format("fl_x%.2f", choke_mult))
        end
        
        -- Average choke info
        if data.avg_choke > 1.5 then
            table.insert(details, string.format("avg_%.1ft", data.avg_choke))
        end
        
    -- ===== DELAY ANTI-AIM HANDLING =====
    elseif data.delay_detected and not is_jittering then
        mode = "DELAY"
        
        -- Predict next update
        local ticks_until_update = data.delay_interval - data.ticks_since_update
        local update_imminent = ticks_until_update <= 2  -- Predict 2 ticks ahead
        local confidence_boost = 1 + (data.delay_confidence * 0.15)  -- Up to 15% boost
        
        if update_imminent and data.delay_interval > 0 then
            -- About to update - AGGRESSIVE prediction
            if abs_desync > 35 then
                -- High desync delay AA
                local base_correction = math.min(abs_desync * 0.98, 60) * confidence_boost
                
                if is_standing then
                    -- Standing delay - predict flip based on history
                    correction = desync > 0 and -base_correction or base_correction
                    
                    -- If high confidence and they flip consistently, prepare for flip
                    if data.delay_confidence > 0.75 and data.last_delay_side ~= 0 then
                        if data.last_delay_side == (desync > 0 and 1 or -1) then
                            -- They stayed same side - likely to flip NOW
                            correction = -correction
                            table.insert(details, "predict_flip")
                        else
                            table.insert(details, "predict_hold")
                        end
                    end
                    
                    table.insert(details, "delay_stand")
                else
                    -- Moving delay
                    correction = desync > 0 and -base_correction or base_correction
                    
                    -- Velocity boost (more aggressive)
                    if math.abs(vel_delta) > 110 then
                        correction = correction + (vel_delta > 0 and 7 or -7)
                        table.insert(details, "vel_boost")
                    elseif math.abs(vel_delta) > 70 then
                        correction = correction + (vel_delta > 0 and 4 or -4)
                    end
                    
                    table.insert(details, "delay_move")
                end
                
                -- Lean (critical for delay AA)
                if math.abs(lean) > 0.4 then
                    correction = correction + (lean > 0 and 16 or -16)
                    table.insert(details, "lean_high")
                elseif math.abs(lean) > 0.25 then
                    correction = correction + (lean > 0 and 12 or -12)
                    table.insert(details, "lean_med")
                elseif math.abs(lean) > 0.1 then
                    correction = correction + (lean > 0 and 8 or -8)
                end
                
                -- 3D vector boost for delay AA
                if angle_difference > 130 then
                    local boost = math.min((angle_difference - 130) * 0.2, 10)
                    correction = correction + (desync > 0 and -boost or boost)
                    table.insert(details, "3d_boost")
                end
            else
                -- Medium/low desync delay
                correction = desync > 0 and -(abs_desync * 0.92) or (abs_desync * 0.92)
                
                if math.abs(lean) > 0.25 then
                    correction = correction + (lean > 0 and 10 or -10)
                end
            end
            
            table.insert(details, string.format("update_%dt", ticks_until_update))
        else
            -- Frozen state - resolve with confidence weighting
            if abs_desync > 35 then
                -- High confidence = more aggressive frozen correction
                local frozen_mult = 0.82 + (data.delay_confidence * 0.10)  -- 0.82-0.92
                correction = desync > 0 and -(abs_desync * frozen_mult) or (abs_desync * frozen_mult)
                
                -- Lean for frozen
                if math.abs(lean) > 0.3 then
                    correction = correction + (lean > 0 and 14 or -14)
                    table.insert(details, "lean_frz")
                elseif math.abs(lean) > 0.18 then
                    correction = correction + (lean > 0 and 10 or -10)
                end
                
                -- Feet yaw rate (important when frozen)
                if math.abs(feet_yaw_rate) > 50 then
                    correction = correction + (feet_yaw_rate > 0 and 8 or -8)
                    table.insert(details, "feet_frz")
                elseif math.abs(feet_yaw_rate) > 30 then
                    correction = correction + (feet_yaw_rate > 0 and 5 or -5)
                end
                
                table.insert(details, "frozen_hi")
            elseif abs_desync > 20 then
                correction = desync > 0 and -(abs_desync * 0.88) or (abs_desync * 0.88)
                
                if math.abs(lean) > 0.25 then
                    correction = correction + (lean > 0 and 9 or -9)
                end
                
                table.insert(details, "frozen_md")
            else
                correction = desync > 0 and -(abs_desync * 0.85) or (abs_desync * 0.85)
                table.insert(details, "frozen_lo")
            end
            
            table.insert(details, string.format("frz_%dt", data.frozen_ticks))
        end
        
        -- Add delay interval and confidence info
        if data.delay_interval > 0 then
            table.insert(details, string.format("int_%dt", data.delay_interval))
            if data.delay_confidence > 0.75 then
                table.insert(details, string.format("conf_%.0f%%", data.delay_confidence * 100))
            end
        end
        
    elseif is_jittering then
        -- Check if jitter + fakelag combo
        if data.choke_amount >= 1 then
            mode = "JITTER+FL"
            table.insert(details, string.format("choke_%d", data.choke_amount))
        else
            mode = "JITTER"
        end
        
        -- ===== STANDING JITTER =====
        if is_standing then
            
            if abs_desync > 38 then
                -- High desync standing
                
                -- LBY update prediction
                local lby_updating_soon = time_stopped > 1.0 and time_stopped < 1.25
                
                if lby_updating_soon then
                    -- LBY about to update - resolve TO current side
                    correction = desync * 0.96
                    mode = "JITTER-LBY↑"
                    table.insert(details, "lby_update")
                else
                    -- Fresh LBY - resolve OPPOSITE side
                    
                    -- OPTIMIZED FORMULA - Standing Jitter
                    -- Key principle: resolve to OPPOSITE side with magnitude close to max desync
                    
                    -- Base angle = actual desync (this is the real body angle)
                    local target_angle = abs_desync
                    
                    -- Direction: OPPOSITE to current eye yaw side
                    correction = desync > 0 and -target_angle or target_angle
                    
                    -- Lean is THE MOST IMPORTANT indicator of real body direction
                    -- Lean > 0 means body leans right, lean < 0 means left
                    -- This adds to correction (can boost or reduce it)
                    correction = correction + (lean * 35)
                    
                    -- Feet yaw rate shows rotation speed and direction
                    correction = correction + (feet_yaw_rate * 0.15)
                    
                    -- If jitter is very aggressive (high velocity), boost correction
                    local jitter_strength = math.abs(data.yaw_velocity) / 100  -- Normalize
                    correction = correction * (1.0 + jitter_strength * 0.10)  -- Up to +10%
                    
                    table.insert(details, "OPT")
                end
                
            else
                -- Medium/Low standing - same principle
                correction = desync > 0 and -abs_desync or abs_desync
                correction = correction + (lean * 30)
                correction = correction + (feet_yaw_rate * 0.12)
            end
            
        -- ===== MOVING JITTER =====
        elseif is_slowwalking or is_walking or is_running then
            
            if abs_desync > 38 then
                -- OPTIMIZED FORMULA - Moving Jitter
                -- While moving, body position is more predictable
                
                -- Base: actual desync
                local target_angle = abs_desync
                
                -- Direction: OPPOSITE
                correction = desync > 0 and -target_angle or target_angle
                
                -- Lean is EVEN MORE important while moving
                correction = correction + (lean * 40)
                
                -- Feet yaw rate (body rotation)
                correction = correction + (feet_yaw_rate * 0.16)
                
                -- Movement direction matters - where is player going?
                if math.abs(move_x) > 1 or math.abs(move_y) > 1 then
                    local move_angle = math.atan2(move_y, move_x) * 57.2958
                    local move_yaw_delta = normalize_angle(move_angle - eye_yaw)
                    -- If moving perpendicular to view, body follows movement
                    correction = correction + (move_yaw_delta * 0.10)
                end
                
                -- Jitter strength boost (higher for moving)
                local jitter_strength = math.abs(data.yaw_velocity) / 100
                correction = correction * (1.0 + jitter_strength * 0.12)  -- Up to +12%
                
                table.insert(details, "OPT")
                
            else
                -- Medium/Low moving - same principle
                correction = desync > 0 and -abs_desync or abs_desync
                correction = correction + (lean * 35)
                correction = correction + (feet_yaw_rate * 0.14)
                
                -- Movement direction
                if math.abs(move_x) > 1 or math.abs(move_y) > 1 then
                    local move_angle = math.atan2(move_y, move_x) * 57.2958
                    local move_delta = normalize_angle(move_angle - eye_yaw)
                    correction = correction + (move_delta * 0.08)
                end
            end
            
        -- ===== AIR JITTER =====
        elseif is_in_air then
            
            if abs_desync > 35 then
                correction = desync > 0 and -56 or 56
                
                if math.abs(lean) > 0.3 then
                    correction = correction + (lean > 0 and 10 or -10)
                end
                
                table.insert(details, "air")
            else
                correction = desync > 0 and -52 or 52
            end
        end
        
    else
        -- ===== NO JITTER - SOFT CORRECTION =====
        mode = "SOFT"
        data.side_flips = 0  -- Reset counter
        
        if abs_desync > 45 then
            -- Very high desync without jitter
            if is_standing and time_stopped > 0.95 then
                -- Predictive correction before LBY update
                correction = desync * 0.92
                table.insert(details, "lby_predict")
            else
                correction = desync > 0 and -(abs_desync * 0.88) or (abs_desync * 0.88)
            end
            
        elseif abs_desync > 30 then
            correction = desync > 0 and -38 or 38
            
        elseif abs_desync > 18 then
            correction = desync > 0 and -28 or 28
            
        elseif abs_desync > 10 then
            correction = desync > 0 and -18 or 18
            
        else
            correction = 0
        end
    end
    
    -- Crouching boost
    if is_crouching and correction ~= 0 then
        correction = correction * 1.04
    end
    
    -- CLAMP - Allow maximum possible correction
    -- desync can be up to 60°, with lean/feet adjustments we can add ~10-15°
    local max_corr = 70
    correction = math.max(-max_corr, math.min(max_corr, correction))
    
    -- Final angle
    local resolved_yaw = normalize_angle(eye_yaw + correction)
    
    -- Apply to animstate
    animstate.m_flGoalFeetYaw = resolved_yaw
    
    -- Update state
    data.was_standing = is_standing
    data.last_speed = speed
    data.last_update = global_vars.cur_time()
    
    -- ===== LOGGING =====
    if cfg_logs:get() then
        local player_name = "Player"
        pcall(function()
            player_name = player:get_name()
        end)
        
        -- Build state string
        local state = ""
        if is_standing then state = "STAND"
        elseif is_running then state = "RUN"
        elseif is_walking then state = "WALK"
        elseif is_slowwalking then state = "SLOW"
        elseif is_in_air then state = "AIR"
        end
        
        if is_crouching then
            state = state .. "+DUCK"
        end
        
        -- Build details string
        local details_str = ""
        if #details > 0 then
            details_str = " [" .. table.concat(details, ",") .. "]"
        end
        
        -- Additional info
        local info_parts = {}
        
        -- Fakelag info (highest priority)
        if data.fakelag_detected then
            if data.breaklag_detected then
                table.insert(info_parts, string.format("BREAKLAG:%dt", data.choke_amount))
            else
                table.insert(info_parts, string.format("FAKELAG:%dt", data.choke_amount))
            end
            if data.avg_choke > 1.5 then
                table.insert(info_parts, string.format("avg:%.1f", data.avg_choke))
            end
            if data.extrapolated_yaw ~= 0 then
                table.insert(info_parts, string.format("extrap:%.0f°", data.extrapolated_yaw))
            end
        end
        
        -- Delay info (priority)
        if data.delay_detected and not data.fakelag_detected then
            table.insert(info_parts, string.format("DELAY:%dt", data.delay_interval))
            if data.frozen_ticks > 0 then
                table.insert(info_parts, string.format("Frozen:%dt", data.frozen_ticks))
            end
            if data.ticks_since_update > 0 then
                table.insert(info_parts, string.format("Since:%dt", data.ticks_since_update))
            end
        end
        
        -- Jitter info
        if is_jittering then
            table.insert(info_parts, string.format("J:%.0f°", max_yaw_change))
        end
        
        -- Side flips
        if data.side_flips > 5 then
            table.insert(info_parts, string.format("SF:%d", data.side_flips))
        end
        
        -- Lean
        if math.abs(lean) > 0.2 then
            table.insert(info_parts, string.format("L:%.2f", lean))
        end
        
        -- Feet rate
        if math.abs(feet_yaw_rate) > 30 then
            table.insert(info_parts, string.format("FR:%d", math.floor(feet_yaw_rate)))
        end
        
        -- 3D angle difference
        if angle_difference > 80 then
            table.insert(info_parts, string.format("3D:%.0f°", angle_difference))
        end
        
        local info_str = ""
        if #info_parts > 0 then
            info_str = " | " .. table.concat(info_parts, " ")
        end
        
        print(string.format(
            "[Resolver] %s | %.1f → %.1f | Δ%d° | %s %s | Corr:%.0f%s%s",
            player_name,
            eye_yaw,
            resolved_yaw,
            math.floor(abs_desync),
            mode,
            state,
            correction,
            details_str,
            info_str
        ))
    end
end

-- Main callback
callbacks.add(e_callbacks.NET_UPDATE, function()
    if not cfg_enable:get() then return end
    
    local local_player = entity_list.get_local_player()
    if not local_player or not local_player:is_alive() then return end
    
    local enemies = entity_list.get_players(true)
    if not enemies then return end
    
    for _, player in pairs(enemies) do
        if player and player:is_alive() and not player:is_dormant() then
            pcall(resolve_player, player)
        end
    end
end)

-- Round start reset
callbacks.add(e_callbacks.EVENT, function()
    for i = 1, 65 do
        player_data[i] = {
            history = {},
            jitter_detected = false,
            jitter_amplitude = 0,
            jitter_frequency = 0,
            yaw_velocity = 0,
            yaw_acceleration = 0,
            jitter_phase = 0,
            harmonic_period = 0,
            jitter_intensity = 0,
            consecutive_high_vel = 0,
            current_side = 0,
            last_side = 0,
            side_flips = 0,
            was_standing = false,
            last_speed = 0,
            last_update = 0,
            last_real_yaw = 0,
            last_yaw_update_tick = 0,
            ticks_since_update = 0,
            delay_detected = false,
            delay_interval = 0,
            frozen_ticks = 0,
            delay_history = {},
            delay_confidence = 0,
            last_delay_side = 0,
            last_simulation_time = 0,
            choke_amount = 0,
            avg_choke = 0,
            fakelag_detected = false,
            breaklag_detected = false,
            velocity_history = {},
            last_origin = nil,
            extrapolated_yaw = 0
        }
    end
    
    if cfg_logs:get() then
        print("[Resolver] Round started - data reset")
    end
end, "round_start")

-- Load message
print("╔═══════════════════════════════════════════════╗")
print("║  Perfect Resolver v7.0 - OPTIMIZED           ║")
print("╠═══════════════════════════════════════════════╣")
print("║  CORE PRINCIPLE:                              ║")
print("║  Fake yaw on one side → Body on OPPOSITE     ║")
print("║                                               ║")
print("║  FORMULA (ULTRA SIMPLE):                      ║")
print("║  1. correction = -desync (opposite)           ║")
print("║  2. correction += lean × 35-40 (KEY!)         ║")
print("║  3. correction += feet_rate × 0.15-0.16       ║")
print("║  4. correction += move_dir × 0.10 (moving)    ║")
print("║  5. correction *= jitter_boost (1.0-1.12)     ║")
print("║                                               ║")
print("║  NO COMPLEX MATH - JUST GEOMETRY              ║")
print("║  NO AI - JUST PHYSICS                         ║")
print("║  NO PATTERNS - JUST REALITY                   ║")
print("║                                               ║")
print("║  Clamp: 70° | Lean = MOST IMPORTANT           ║")
print("╚═══════════════════════════════════════════════╝")
