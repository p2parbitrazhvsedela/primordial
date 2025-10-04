--[[
    Advanced Jitter Correction Resolver v3.0
    Uses FFI direct animstate access with intelligent jitter detection
    No random - pure logic based resolution
]]

local ffi = require("ffi")

-- Full CAnimstate structure (from working code)
ffi.cdef[[
    typedef uintptr_t (__thiscall* GetClientEntity_123123_t)(void*, int);
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

-- Get entity interface
local RawIEntityList = ffi.cast("void***", memory.create_interface("client.dll", "VClientEntityList003"))
local IEntityList = ffi.cast("GetClientEntity_123123_t", RawIEntityList[0][3])

local function GetEntityPattern(index)
    return IEntityList(RawIEntityList, index)
end

-- Configuration
local cfg_resolver = menu.add_checkbox("Advanced Resolver | Settings", "Enable Resolver", false)
local cfg_logs = menu.add_checkbox("Advanced Resolver | Settings", "Enable Logs", false)

-- Resolver data storage
local resolver_data = {}
local MAX_PLAYERS = 65

for i = 1, MAX_PLAYERS do
    resolver_data[i] = {
        history = {},
        jitter_detected = false,
        consecutive_jitters = 0,
        miss_count = 0,
        brute_phase = 0,
        last_update = 0,
        last_side = 0,
        side_changes = 0
    }
end

-- Normalize angle
local function normalize_angle(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

-- Safe animstate access
local function get_animstate(player)
    if not player then return nil end
    
    local success, animstate = pcall(function()
        local entity_ptr = GetEntityPattern(player:get_index())
        if entity_ptr == nil then return nil end
        
        local animstate_ptr = ffi.cast("struct CAnimstate**", entity_ptr + 0x9960)[0]
        return animstate_ptr
    end)
    
    if success and animstate then
        return animstate
    else
        if cfg_logs:get() then
            print("[Resolver] Failed to get animstate for player " .. tostring(player:get_index()))
        end
        return nil
    end
end

-- Main resolver logic
local function resolve_player(player)
    if not player or player:is_dormant() then return end
    
    local player_index = player:get_index()
    local data = resolver_data[player_index]
    
    -- Get animstate
    local animstate = get_animstate(player)
    if not animstate then return end
    
    -- Read current state from animstate
    local eye_yaw = animstate.m_flEyeYaw
    local goal_feet_yaw = animstate.m_flGoalFeetYaw
    local current_feet_yaw = animstate.m_flCurrentFeetYaw
    local speed_2d = animstate.m_flSpeed2D
    local on_ground = animstate.m_bOnGround
    local duck_amount = animstate.m_fDuckAmount
    local lean_amount = animstate.m_flLeanAmount
    local feet_yaw_rate = animstate.m_flFeetYawRate or 0
    local time_since_stopped = animstate.m_flTimeSinceStoppedMoving or 0
    local time_since_started = animstate.m_flTimeSinceStartedMoving or 0
    local velocity_x = animstate.m_vVelocityX or 0
    local velocity_y = animstate.m_vVelocityY or 0
    
    -- Calculate desync
    local desync = normalize_angle(eye_yaw - goal_feet_yaw)
    local abs_desync = math.abs(desync)
    
    -- Calculate velocity angle
    local velocity_angle = math.deg(math.atan2(velocity_y, velocity_x))
    local velocity_delta = normalize_angle(eye_yaw - velocity_angle)
    
    -- Store history
    table.insert(data.history, {
        eye_yaw = eye_yaw,
        goal_feet_yaw = goal_feet_yaw,
        current_feet_yaw = current_feet_yaw,
        desync = abs_desync,
        desync_signed = desync,
        speed = speed_2d,
        on_ground = on_ground,
        duck = duck_amount,
        lean = lean_amount,
        feet_rate = feet_yaw_rate,
        time_stopped = time_since_stopped,
        time_started = time_since_started,
        vel_delta = velocity_delta,
        time = global_vars.cur_time()
    })
    
    -- Keep last 6 records
    if #data.history > 6 then
        table.remove(data.history, 1)
    end
    
    -- Need at least 3 frames for analysis
    if #data.history < 3 then return end
    
    local curr = data.history[#data.history]
    local prev = data.history[#data.history - 1]
    local prev2 = data.history[#data.history - 2]
    
    -- Advanced jitter detection with pattern analysis
    local yaw_change = math.abs(curr.eye_yaw - prev.eye_yaw)
    local feet_change = math.abs(curr.goal_feet_yaw - prev.goal_feet_yaw)
    local side_flip = (curr.desync_signed * prev.desync_signed) < 0
    local side_flip2 = (prev.desync_signed * prev2.desync_signed) < 0
    
    -- Track side changes for pattern prediction
    local current_side = desync > 0 and 1 or -1
    if current_side ~= data.last_side and data.last_side ~= 0 then
        data.side_changes = data.side_changes + 1
    end
    data.last_side = current_side
    
    local resolved_yaw = goal_feet_yaw
    local correction = 0
    
    -- Check if standing with LBY update prediction
    local standing = speed_2d < 5
    local lby_about_to_update = standing and time_since_stopped > 0.9 and time_since_stopped < 1.3
    
    -- Calculate average jitter amplitude
    local avg_jitter = 0
    if #data.history >= 3 then
        local sum = 0
        for i = #data.history - 2, #data.history - 1 do
            sum = sum + math.abs(data.history[i+1].eye_yaw - data.history[i].eye_yaw)
        end
        avg_jitter = sum / 2
    end
    
    -- Jitter detection with multiple indicators
    local is_jittering = (yaw_change > 28 or feet_change > 30) or (side_flip and side_flip2)
    
    if is_jittering then
        data.jitter_detected = true
        data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 20)
        
        -- Adaptive brute force after misses
        if data.miss_count > 2 then
            -- Use successful corrections if available
            if #data.successful_corrections > 0 and data.miss_count < 5 then
                -- Try previous successful correction
                local success_idx = ((data.brute_phase % #data.successful_corrections) + 1)
                correction = data.successful_corrections[success_idx]
            else
                -- Cycle through extended angles based on jitter amplitude
                local brute_angles
                if avg_jitter > 70 then
                    -- Heavy jitter
                    brute_angles = {60, -60, 58, -58, 52, -52, 0}
                elseif avg_jitter > 40 then
                    -- Medium jitter  
                    brute_angles = {58, -58, 50, -50, 45, -45}
                else
                    -- Light jitter
                    brute_angles = {52, -52, 48, -48, 40, -40}
                end
                
                data.brute_phase = (data.brute_phase + 1) % #brute_angles
                correction = brute_angles[data.brute_phase + 1]
            end
            resolved_yaw = eye_yaw + correction
        else
            -- Intelligent resolution with learning
            
            -- Try to use best correction if we have a streak
            if data.correction_streak > 2 and data.best_correction ~= 0 then
                correction = data.best_correction
            else
                if standing then
                    -- Standing jitter with LBY timing
                    if abs_desync > 35 then
                        if lby_about_to_update then
                            -- LBY will update soon - resolve to current side
                            correction = desync * 0.92
                        else
                            -- LBY fresh - resolve opposite with confidence
                            local base = desync > 0 and -58 or 58
                            
                            -- Adjust based on jitter amplitude
                            if avg_jitter > 70 then
                                base = desync > 0 and -60 or 60
                            elseif avg_jitter < 40 then
                                base = desync > 0 and -54 or 54
                            end
                            
                            correction = base
                            
                            -- Pattern prediction for heavy switching
                            if data.side_changes > 10 then
                                local predicted = data.consecutive_jitters % 4
                                if predicted == 0 then correction = 60
                                elseif predicted == 1 then correction = -60
                                elseif predicted == 2 then correction = 55 * current_side
                                else correction = -55 * current_side end
                            elseif data.side_changes > 6 then
                                -- Medium switching - simple alternation
                                if data.consecutive_jitters % 2 == 0 then
                                    correction = -correction
                                end
                            end
                        end
                    elseif abs_desync > 20 then
                        -- Medium desync standing
                        correction = data.consecutive_jitters % 2 == 0 and 52 or -52
                    else
                        -- Low desync standing
                        correction = data.consecutive_jitters % 2 == 0 and 48 or -48
                    end
                else
                    -- Moving jitter with velocity consideration
                    if abs_desync > 35 then
                        -- High desync moving
                        local base_corr = desync > 0 and -57 or 57
                        
                        -- Adjust for jitter amplitude
                        if avg_jitter > 70 then
                            base_corr = desync > 0 and -60 or 60
                        elseif avg_jitter < 40 then
                            base_corr = desync > 0 and -52 or 52
                        end
                        
                        -- Consider velocity direction
                        if math.abs(curr.vel_delta) > 100 then
                            -- Moving backwards/sideways - more predictable
                            base_corr = base_corr * 1.10
                        elseif math.abs(curr.vel_delta) > 80 then
                            base_corr = base_corr * 1.05
                        end
                        
                        -- Alternation for heavy jitter
                        if data.consecutive_jitters > 6 then
                            local alt_phase = data.consecutive_jitters % 3
                            if alt_phase == 1 then
                                base_corr = -base_corr
                            elseif alt_phase == 2 then
                                base_corr = base_corr * 0.9
                            end
                        elseif data.consecutive_jitters > 3 then
                            if data.consecutive_jitters % 2 == 0 then
                                base_corr = -base_corr
                            end
                        end
                        
                        correction = base_corr
                    elseif abs_desync > 22 then
                        -- Medium desync moving
                        correction = data.consecutive_jitters % 2 == 0 and 54 or -54
                    else
                        -- Low desync moving
                        correction = data.consecutive_jitters % 2 == 0 and 50 or -50
                    end
                end
            end
            
            -- Lean amount micro-adjustment (more aggressive)
            if math.abs(lean_amount) > 0.25 then
                local lean_corr = lean_amount > 0 and 10 or -10
                correction = correction + lean_corr
            end
            
            -- Feet yaw rate adjustment (predicts where feet are going)
            if math.abs(feet_yaw_rate) > 30 then
                local rate_corr = feet_yaw_rate > 0 and 5 or -5
                correction = correction + rate_corr
            end
            
            -- Duck amount boost
            if duck_amount > 0.5 then
                correction = correction * 1.03
            end
            
            resolved_yaw = eye_yaw + correction
        end
    else
        -- No jitter detected
        data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
        if data.consecutive_jitters == 0 then
            data.jitter_detected = false
            data.miss_count = 0
            data.side_changes = 0
        end
        
        -- Soft correction based on state
        if abs_desync > 35 then
            if standing and lby_about_to_update then
                -- Predictive correction before LBY update
                correction = desync * 0.95
            else
                -- Standard opposite correction
                correction = desync > 0 and -(abs_desync * 0.82) or (abs_desync * 0.82)
            end
            resolved_yaw = eye_yaw + correction
        elseif abs_desync > 18 then
            -- Medium desync soft correction
            correction = desync > 0 and -28 or 28
            resolved_yaw = eye_yaw + correction
        elseif abs_desync > 8 then
            -- Low desync micro-correction
            correction = desync > 0 and -15 or 15
            resolved_yaw = eye_yaw + correction
        end
    end
    
    -- Normalize resolved angle
    resolved_yaw = normalize_angle(resolved_yaw)
    
    -- Store correction for learning
    data.last_correction = math.floor(correction)
    
    -- Apply resolved angle to animstate
    animstate.m_flGoalFeetYaw = resolved_yaw
    
    -- Logging
    if cfg_logs:get() then
        local player_name = "Player"
        local success_name, name_result = pcall(function()
            return player:get_name()
        end)
        if success_name and name_result then
            player_name = name_result
        end
        
        local mode = "SOFT"
        local mode_detail = ""
        
        if data.jitter_detected then
            if data.miss_count > 2 then
                mode = "BRUTE#" .. tostring(data.brute_phase)
            else
                mode = "JITTER"
                if standing then
                    mode_detail = lby_about_to_update and " LBY↑" or " STAND"
                else
                    mode_detail = " MOVE"
                end
            end
        else
            if standing and lby_about_to_update then
                mode_detail = " LBY↑"
            end
        end
        
        -- Add side change indicator
        local pattern_info = ""
        if data.side_changes > 5 then
            pattern_info = string.format(" | SC:%d", data.side_changes)
        end
        
        local log_msg = string.format(
            "[Resolver] %s | %.1f→%.1f | Δ%d° | Corr:%.1f | %s%s | M:%d%s",
            tostring(player_name),
            tostring(eye_yaw),
            tostring(resolved_yaw),
            tostring(math.floor(abs_desync)),
            tostring(math.floor(correction)),
            mode,
            mode_detail,
            tostring(data.miss_count),
            pattern_info
        )
        print(log_msg)
    end
end

-- Main callback
local function on_net_update()
    if not cfg_resolver:get() then return end
    
    local local_player = entity_list.get_local_player()
    if not local_player or not local_player:is_alive() then return end
    
    local players = entity_list.get_players(true)
    if not players then return end
    
    for _, player in pairs(players) do
        if player and player:is_alive() and not player:is_dormant() then
            local success, error_msg = pcall(function()
                resolve_player(player)
            end)
            
            if not success and cfg_logs:get() then
                print("[Resolver] Error: " .. tostring(error_msg))
            end
        end
    end
end

-- Handle hits for learning
local function on_aimbot_hit(hit)
    if not cfg_resolver:get() then return end
    
    local player_index = hit.player:get_index()
    if not player_index then return end
    
    local data = resolver_data[player_index]
    if not data then return end
    
    data.hit_count = data.hit_count + 1
    data.correction_streak = data.correction_streak + 1
    
    -- Store successful correction
    if data.last_correction ~= 0 then
        table.insert(data.successful_corrections, data.last_correction)
        
        -- Keep only last 5 successful corrections
        if #data.successful_corrections > 5 then
            table.remove(data.successful_corrections, 1)
        end
        
        -- Update best correction if we have a streak
        if data.correction_streak > 2 then
            data.best_correction = data.last_correction
        end
    end
    
    -- Reset miss count on hit
    if data.miss_count > 0 then
        data.miss_count = math.max(data.miss_count - 1, 0)
    end
    
    if cfg_logs:get() then
        print(string.format("[Resolver] ✓ HIT player %d | Corr: %d | Streak: %d", 
            tostring(player_index), 
            tostring(data.last_correction),
            tostring(data.correction_streak)))
    end
end

-- Handle misses
local function on_aimbot_miss(miss)
    if not cfg_resolver:get() then return end
    
    local player_index = miss.player:get_index()
    if not player_index then return end
    
    local data = resolver_data[player_index]
    if not data then return end
    
    data.miss_count = math.min(data.miss_count + 1, 8)
    data.correction_streak = 0  -- Reset streak on miss
    
    -- Reset best correction after multiple misses
    if data.miss_count > 3 then
        data.best_correction = 0
    end
    
    if cfg_logs:get() then
        print(string.format("[Resolver] ✗ MISS player %d | Last corr: %d | Total miss: %d", 
            tostring(player_index),
            tostring(data.last_correction),
            tostring(data.miss_count)))
    end
end

-- Reset on round start
local function on_round_start()
    if cfg_logs:get() then
        print("[Resolver] Round started - resetting data")
    end
    
    for i = 1, MAX_PLAYERS do
        resolver_data[i] = {
            history = {},
            jitter_detected = false,
            consecutive_jitters = 0,
            miss_count = 0,
            brute_phase = 0,
            last_update = 0,
            last_side = 0,
            side_changes = 0,
            predicted_side = 0
        }
    end
end

-- Cleanup
local function on_shutdown()
    if cfg_logs:get() then
        print("[Resolver] Shutting down")
    end
    resolver_data = {}
end

-- Register callbacks
callbacks.add(e_callbacks.NET_UPDATE, on_net_update)
callbacks.add(e_callbacks.AIMBOT_MISS, on_aimbot_miss)
callbacks.add(e_callbacks.EVENT, on_round_start, "round_start")
callbacks.add(e_callbacks.SHUTDOWN, on_shutdown)

-- Load message
print("[Resolver] Advanced Resolver v3.1 loaded")
print("[Resolver] Features:")
print("  • FFI direct animstate access")
print("  • LBY update prediction")
print("  • Pattern-based side prediction")
print("  • Velocity & lean micro-adjustments")
print("  • Smart adaptive brute force")
if cfg_logs:get() then
    print("[Resolver] Debug logs enabled")
end
