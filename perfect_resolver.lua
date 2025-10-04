--[[
    Perfect Jitter Resolver v6.0
    Maximum detail and accuracy
    No ML, No brute force - just pure intelligent logic
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
        
        -- Side tracking
        current_side = 0,
        last_side = 0,
        side_flips = 0,
        
        -- State tracking
        was_standing = false,
        last_speed = 0,
        
        -- Timing
        last_update = 0
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
    
    -- Update jitter metrics
    data.jitter_amplitude = max_yaw_change
    
    -- Jitter detection with multiple conditions
    local is_jittering = 
        (yaw_change > 35) or                           -- Large yaw change
        (yaw_change > 28 and side_flip) or            -- Medium change with flip
        (double_flip) or                               -- Double side flip
        (desync_change > 35)                          -- Large desync change
    
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
    
    if is_jittering then
        mode = "JITTER"
        
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
                    
                    -- Base angle depends on jitter amplitude
                    local base_angle = 58
                    if max_yaw_change > 85 then
                        base_angle = 60
                        table.insert(details, "heavy_jitter")
                    elseif max_yaw_change > 65 then
                        base_angle = 59
                        table.insert(details, "strong_jitter")
                    elseif max_yaw_change > 45 then
                        base_angle = 58
                        table.insert(details, "medium_jitter")
                    else
                        base_angle = 56
                        table.insert(details, "light_jitter")
                    end
                    
                    -- Apply opposite direction
                    correction = desync > 0 and -base_angle or base_angle
                    
                    -- Lean correction (very important for standing)
                    if math.abs(lean) > 0.4 then
                        local lean_adjust = lean > 0 and 14 or -14
                        correction = correction + lean_adjust
                        table.insert(details, "lean_high")
                    elseif math.abs(lean) > 0.25 then
                        local lean_adjust = lean > 0 and 10 or -10
                        correction = correction + lean_adjust
                        table.insert(details, "lean_med")
                    elseif math.abs(lean) > 0.1 then
                        local lean_adjust = lean > 0 and 6 or -6
                        correction = correction + lean_adjust
                        table.insert(details, "lean_low")
                    end
                    
                    -- Side flip adjustment
                    if data.side_flips > 10 then
                        -- Very unstable jitter
                        local flip_adjust = (data.side_flips % 4) - 2
                        correction = correction + (flip_adjust * 3)
                        table.insert(details, "unstable")
                    elseif data.side_flips > 6 then
                        -- Moderately unstable
                        local flip_adjust = (data.side_flips % 3) - 1
                        correction = correction + (flip_adjust * 2)
                        table.insert(details, "switching")
                    end
                end
                
            elseif abs_desync > 25 then
                -- Medium desync standing
                correction = desync > 0 and -54 or 54
                
                if max_yaw_change > 60 then
                    correction = correction * 1.05
                end
                
            elseif abs_desync > 15 then
                -- Low desync standing
                correction = desync > 0 and -50 or 50
                
            else
                -- Very low desync
                correction = desync > 0 and -45 or 45
            end
            
        -- ===== MOVING JITTER =====
        elseif is_slowwalking or is_walking or is_running then
            
            if abs_desync > 38 then
                -- High desync moving
                
                -- Base angle by jitter amplitude
                local base_angle = 58
                if max_yaw_change > 85 then
                    base_angle = 60
                elseif max_yaw_change > 65 then
                    base_angle = 59
                elseif max_yaw_change > 45 then
                    base_angle = 58
                else
                    base_angle = 56
                end
                
                correction = desync > 0 and -base_angle or base_angle
                
                -- Velocity direction analysis
                if math.abs(vel_delta) > 110 then
                    -- Moving backwards or very sideways
                    local vel_adjust = vel_delta > 0 and 6 or -6
                    correction = correction + vel_adjust
                    table.insert(details, "backpedal")
                elseif math.abs(vel_delta) > 85 then
                    -- Sideways movement
                    local vel_adjust = vel_delta > 0 and 4 or -4
                    correction = correction + vel_adjust
                    table.insert(details, "strafe")
                end
                
                -- Feet yaw rate (predicts where body is rotating)
                if math.abs(feet_yaw_rate) > 60 then
                    local feet_adjust = feet_yaw_rate > 0 and 10 or -10
                    correction = correction + feet_adjust
                    table.insert(details, "feet_fast")
                elseif math.abs(feet_yaw_rate) > 40 then
                    local feet_adjust = feet_yaw_rate > 0 and 6 or -6
                    correction = correction + feet_adjust
                    table.insert(details, "feet_med")
                elseif math.abs(feet_yaw_rate) > 20 then
                    local feet_adjust = feet_yaw_rate > 0 and 3 or -3
                    correction = correction + feet_adjust
                end
                
                -- Lean correction (critical for moving jitter)
                if math.abs(lean) > 0.35 then
                    local lean_adjust = lean > 0 and 16 or -16
                    correction = correction + lean_adjust
                    table.insert(details, "lean_high")
                elseif math.abs(lean) > 0.2 then
                    local lean_adjust = lean > 0 and 12 or -12
                    correction = correction + lean_adjust
                    table.insert(details, "lean_med")
                elseif math.abs(lean) > 0.1 then
                    local lean_adjust = lean > 0 and 8 or -8
                    correction = correction + lean_adjust
                    table.insert(details, "lean_low")
                end
                
            elseif abs_desync > 25 then
                -- Medium desync moving
                correction = desync > 0 and -54 or 54
                
                if math.abs(lean) > 0.25 then
                    correction = correction + (lean > 0 and 10 or -10)
                end
                
            else
                -- Low desync moving
                correction = desync > 0 and -50 or 50
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
        if is_jittering then
            table.insert(info_parts, string.format("J:%.0f°", max_yaw_change))
        end
        if data.side_flips > 5 then
            table.insert(info_parts, string.format("SF:%d", data.side_flips))
        end
        if math.abs(lean) > 0.2 then
            table.insert(info_parts, string.format("L:%.2f", lean))
        end
        if math.abs(feet_yaw_rate) > 30 then
            table.insert(info_parts, string.format("FR:%d", math.floor(feet_yaw_rate)))
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
            current_side = 0,
            last_side = 0,
            side_flips = 0,
            was_standing = false,
            last_speed = 0,
            last_update = 0
        }
    end
    
    if cfg_logs:get() then
        print("[Resolver] Round started - data reset")
    end
end, "round_start")

-- Load message
print("╔════════════════════════════════════════╗")
print("║  Perfect Jitter Resolver v6.0         ║")
print("║  Detailed analysis, maximum accuracy   ║")
print("║  No ML, No brute - Pure intelligence   ║")
print("╚════════════════════════════════════════╝")
