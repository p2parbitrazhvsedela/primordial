--[[
    Clean Jitter Resolver v4.0
    Pure logic based resolution using FFI animstate
    No ML, no brute force - just smart analysis
]]

local ffi = require("ffi")

-- CAnimstate structure
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
local cfg_resolver = menu.add_checkbox("Clean Resolver | Settings", "Enable Resolver", false)
local cfg_logs = menu.add_checkbox("Clean Resolver | Settings", "Enable Logs", false)

-- Resolver data
local resolver_data = {}
local MAX_PLAYERS = 65

for i = 1, MAX_PLAYERS do
    resolver_data[i] = {
        history = {},
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

-- Get animstate
local function get_animstate(player)
    if not player then return nil end
    
    local success, animstate = pcall(function()
        local entity_ptr = GetEntityPattern(player:get_index())
        if entity_ptr == nil then return nil end
        return ffi.cast("struct CAnimstate**", entity_ptr + 0x9960)[0]
    end)
    
    return (success and animstate) or nil
end

-- Main resolver
local function resolve_player(player)
    if not player or player:is_dormant() then return end
    
    local player_index = player:get_index()
    local data = resolver_data[player_index]
    
    local animstate = get_animstate(player)
    if not animstate then return end
    
    -- Read animstate data
    local eye_yaw = animstate.m_flEyeYaw
    local goal_feet_yaw = animstate.m_flGoalFeetYaw
    local current_feet_yaw = animstate.m_flCurrentFeetYaw
    local speed = animstate.m_flSpeed2D
    local lean = animstate.m_flLeanAmount
    local feet_rate = animstate.m_flFeetYawRate or 0
    local time_stopped = animstate.m_flTimeSinceStoppedMoving or 0
    
    -- Calculate desync
    local desync = normalize_angle(eye_yaw - goal_feet_yaw)
    local abs_desync = math.abs(desync)
    
    -- Store history
    table.insert(data.history, {
        eye_yaw = eye_yaw,
        desync_signed = desync,
        desync = abs_desync,
        speed = speed,
        lean = lean,
        feet_rate = feet_rate,
        time_stopped = time_stopped
    })
    
    if #data.history > 5 then
        table.remove(data.history, 1)
    end
    
    -- Need history for detection
    if #data.history < 3 then return end
    
    local curr = data.history[#data.history]
    local prev = data.history[#data.history - 1]
    local prev2 = data.history[#data.history - 2]
    
    -- Detect jitter by yaw changes
    local yaw_change = math.abs(curr.eye_yaw - prev.eye_yaw)
    local yaw_change2 = math.abs(prev.eye_yaw - prev2.eye_yaw)
    local side_flip = (curr.desync_signed * prev.desync_signed) < 0
    
    -- Track side changes
    local current_side = desync > 0 and 1 or -1
    if current_side ~= data.last_side and data.last_side ~= 0 then
        data.side_changes = data.side_changes + 1
    end
    data.last_side = current_side
    
    local resolved_yaw = goal_feet_yaw
    local correction = 0
    local mode = "IDLE"
    
    -- Check state
    local standing = speed < 5
    local moving = speed >= 5 and speed < 150
    local running = speed >= 150
    
    -- Detect jitter
    local is_jittering = yaw_change > 30 or (yaw_change > 20 and side_flip)
    
    if is_jittering then
        mode = "JITTER"
        
        -- Calculate average jitter amplitude
        local avg_change = (yaw_change + yaw_change2) / 2
        
        if standing then
            -- Standing jitter resolution
            if abs_desync > 35 then
                -- High desync standing
                if time_stopped > 1.0 and time_stopped < 1.3 then
                    -- LBY about to update - resolve current side
                    correction = desync * 0.95
                    mode = "JITTER-LBY↑"
                else
                    -- Fresh LBY - resolve opposite
                    if avg_change > 70 then
                        -- Heavy jitter
                        correction = desync > 0 and -60 or 60
                    elseif avg_change > 45 then
                        -- Medium jitter
                        correction = desync > 0 and -58 or 58
                    else
                        -- Light jitter
                        correction = desync > 0 and -55 or 55
                    end
                    
                    -- Add lean micro-correction
                    if math.abs(lean) > 0.3 then
                        correction = correction + (lean > 0 and 8 or -8)
                    end
                end
            elseif abs_desync > 20 then
                -- Medium desync
                correction = desync > 0 and -50 or 50
            else
                -- Low desync
                correction = desync > 0 and -45 or 45
            end
        elseif moving or running then
            -- Moving jitter resolution
            if abs_desync > 35 then
                -- High desync moving
                local base = desync > 0 and -58 or 58
                
                -- Adjust for jitter amplitude
                if avg_change > 70 then
                    base = desync > 0 and -60 or 60
                elseif avg_change < 40 then
                    base = desync > 0 and -54 or 54
                end
                
                -- Feet yaw rate prediction
                if math.abs(feet_rate) > 40 then
                    base = base + (feet_rate > 0 and 6 or -6)
                end
                
                correction = base
            elseif abs_desync > 20 then
                -- Medium desync
                correction = desync > 0 and -52 or 52
            else
                -- Low desync
                correction = desync > 0 and -48 or 48
            end
            
            -- Lean adjustment
            if math.abs(lean) > 0.25 then
                correction = correction + (lean > 0 and 10 or -10)
            end
        end
    else
        -- No jitter - soft correction
        mode = "SOFT"
        data.side_changes = 0
        
        if abs_desync > 35 then
            -- High desync no jitter
            if standing and time_stopped > 0.9 then
                -- Predictive LBY correction
                correction = desync * 0.88
                mode = "SOFT-LBY"
            else
                -- Standard opposite
                correction = desync > 0 and -(abs_desync * 0.85) or (abs_desync * 0.85)
            end
        elseif abs_desync > 18 then
            -- Medium desync
            correction = desync > 0 and -30 or 30
        elseif abs_desync > 10 then
            -- Low desync
            correction = desync > 0 and -18 or 18
        end
    end
    
    -- Apply correction
    resolved_yaw = normalize_angle(eye_yaw + correction)
    animstate.m_flGoalFeetYaw = resolved_yaw
    
    -- Logging
    if cfg_logs:get() then
        local player_name = "Player"
        local success, name = pcall(function() return player:get_name() end)
        if success and name then player_name = name end
        
        local state = standing and "STAND" or (running and "RUN" or "MOVE")
        local side_info = data.side_changes > 5 and string.format(" SC:%d", data.side_changes) or ""
        
        print(string.format(
            "[Resolver] %s | %.1f→%.1f | Δ%d° | %s %s | Corr:%d%s",
            player_name,
            eye_yaw,
            resolved_yaw,
            math.floor(abs_desync),
            mode,
            state,
            math.floor(correction),
            side_info
        ))
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
            pcall(function() resolve_player(player) end)
        end
    end
end

-- Reset on round start
local function on_round_start()
    for i = 1, MAX_PLAYERS do
        resolver_data[i] = {
            history = {},
            last_side = 0,
            side_changes = 0
        }
    end
end

-- Register callbacks
callbacks.add(e_callbacks.NET_UPDATE, on_net_update)
callbacks.add(e_callbacks.EVENT, on_round_start, "round_start")

-- Load message
print("[Resolver] Clean Resolver v4.0 loaded")
print("[Resolver] Pure logic - No ML, No brute force")
print("[Resolver] Features: LBY timing, jitter detection, lean/feet rate")
