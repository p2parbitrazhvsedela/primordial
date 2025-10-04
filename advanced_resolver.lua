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
        last_update = 0
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
    
    -- Calculate desync
    local desync = normalize_angle(eye_yaw - goal_feet_yaw)
    local abs_desync = math.abs(desync)
    
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
    
    -- Detect jitter patterns
    local yaw_change = math.abs(curr.eye_yaw - prev.eye_yaw)
    local feet_change = math.abs(curr.goal_feet_yaw - prev.goal_feet_yaw)
    local side_flip = (curr.desync_signed * prev.desync_signed) < 0
    
    local resolved_yaw = goal_feet_yaw -- Default: no change
    local correction = 0
    
    -- Jitter detection
    local is_jittering = (yaw_change > 30 or feet_change > 35) or side_flip
    
    if is_jittering then
        data.jitter_detected = true
        data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 20)
        
        -- Brute force mode after 3 misses
        if data.miss_count > 2 then
            data.brute_phase = (data.brute_phase + 1) % 3
            
            if data.brute_phase == 0 then
                correction = 60
            elseif data.brute_phase == 1 then
                correction = -60
            else
                correction = 0
            end
            
            resolved_yaw = eye_yaw + correction
        else
            -- Smart resolution based on animstate data
            
            -- Check if standing
            local standing = speed_2d < 5
            
            if standing then
                -- Standing jitter
                if abs_desync > 35 then
                    -- High desync - resolve opposite
                    correction = desync > 0 and -58 or 58
                else
                    -- Low desync - alternate
                    correction = data.consecutive_jitters % 2 == 0 and 50 or -50
                end
            else
                -- Moving jitter
                if abs_desync > 35 then
                    -- Resolve based on desync side with alternation
                    local base_corr = desync > 0 and -56 or 56
                    
                    if data.consecutive_jitters > 5 then
                        -- Heavy jitter - alternate
                        if data.consecutive_jitters % 2 == 0 then
                            base_corr = -base_corr
                        end
                    end
                    
                    correction = base_corr
                else
                    -- Medium desync
                    correction = data.consecutive_jitters % 2 == 0 and 52 or -52
                end
            end
            
            -- Use lean amount for micro-adjustment
            if math.abs(lean_amount) > 0.3 then
                local lean_corr = lean_amount > 0 and 8 or -8
                correction = correction + lean_corr
            end
            
            -- Apply correction
            resolved_yaw = eye_yaw + correction
        end
    else
        -- No jitter - decay counter
        data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
        if data.consecutive_jitters == 0 then
            data.jitter_detected = false
            data.miss_count = 0
        end
        
        -- Soft correction based on desync
        if abs_desync > 35 then
            correction = desync > 0 and -(abs_desync * 0.8) or (abs_desync * 0.8)
            resolved_yaw = eye_yaw + correction
        elseif abs_desync > 15 then
            correction = desync > 0 and -25 or 25
            resolved_yaw = eye_yaw + correction
        end
    end
    
    -- Normalize resolved angle
    resolved_yaw = normalize_angle(resolved_yaw)
    
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
        if data.jitter_detected then
            if data.miss_count > 2 then
                mode = "BRUTE"
            else
                mode = "JITTER"
            end
        end
        
        local log_msg = string.format(
            "[Resolver] %s | Eye:%.1f Goal:%.1f→%.1f | Δ%d° | Corr:%.1f | %s | M:%d",
            tostring(player_name),
            tostring(eye_yaw),
            tostring(goal_feet_yaw),
            tostring(resolved_yaw),
            tostring(math.floor(abs_desync)),
            tostring(correction),
            mode,
            tostring(data.miss_count)
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

-- Handle misses
local function on_aimbot_miss(miss)
    if not cfg_resolver:get() then return end
    
    local player_index = miss.player:get_index()
    if not player_index then return end
    
    local data = resolver_data[player_index]
    if not data then return end
    
    data.miss_count = math.min(data.miss_count + 1, 5)
    
    if cfg_logs:get() then
        print(string.format("[Resolver] Miss on player %d (Total: %d)", 
            tostring(player_index), 
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
            last_update = 0
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
print("[Resolver] Advanced Resolver v3.0 loaded")
print("[Resolver] Features: FFI animstate, smart jitter detection, adaptive brute")
if cfg_logs:get() then
    print("[Resolver] Debug logs enabled")
end
