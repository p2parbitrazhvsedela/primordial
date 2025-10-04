--[[
    Jitter Correction Resolver
    Uses FFI and Animation Layers for accurate enemy yaw resolution
    Static method implementation without mode selection
]]

local ffi = require("ffi")

-- FFI Definitions for Animation Layers and AnimState
ffi.cdef[[
    typedef struct {
        float m_flCycle;
        float m_flWeight;
        float m_flPlaybackRate;
        float m_flPrevCycle;
        int m_nOrder;
        int m_nSequence;
    } C_AnimationLayer;
    
    typedef struct {
        char    pad0[0x60];
        void*   pEntity;
        void*   pActiveWeapon;
        void*   pLastActiveWeapon;
        float   flLastUpdateTime;
        int     iLastUpdateFrame;
        float   flLastUpdateIncrement;
        float   flEyeYaw;
        float   flEyePitch;
        float   flGoalFeetYaw;
        float   flLastFeetYaw;
        float   flMoveYaw;
        float   flLastMoveYaw;
        float   flLeanAmount;
        char    pad1[0x4];
        float   flFeetCycle;
        float   flMoveWeight;
        float   flMoveWeightSmoothed;
        float   flDuckAmount;
        float   flHitGroundCycle;
        float   flRecrouchWeight;
    } CCSGOPlayerAnimState;
]]

-- Configuration UI using proper menu system
local cfg_resolver = menu.add_checkbox("Jitter Resolver | Settings", "Enable Resolver", false)
local cfg_logs = menu.add_checkbox("Jitter Resolver | Settings", "Enable Logs", false)

-- Resolver Data Storage
local resolver_data = {}
local MAX_PLAYERS = 65

-- Initialize resolver data for all players
for i = 1, MAX_PLAYERS do
    resolver_data[i] = {
        last_yaw = 0,
        last_sim_time = 0,
        jitter_detected = false,
        jitter_side = 0,
        layer_history = {},
        resolve_angle = 0,
        consecutive_jitters = 0,
        last_velocity = 0
    }
end

-- Safe FFI access wrapper
local function safe_get_animlayers(player)
    if not player then
        return nil
    end
    
    local success, result = pcall(function()
        local layers_ptr = player:get_anim_layers()
        if not layers_ptr or layers_ptr == nil then
            return nil
        end
        
        return ffi.cast("C_AnimationLayer*", layers_ptr)
    end)
    
    if success and result then
        return result
    else
        if cfg_logs:get() then
            print("[Resolver] FFI Error (safe_get_animlayers): " .. tostring(result))
        end
        return nil
    end
end

-- Safe animstate access
local function safe_get_animstate(player)
    if not player then
        return nil
    end
    
    local success, result = pcall(function()
        local animstate_ptr = player:get_anim_state()
        if not animstate_ptr or animstate_ptr == nil then
            return nil
        end
        
        return ffi.cast("CCSGOPlayerAnimState*", animstate_ptr)
    end)
    
    if success and result then
        return result
    else
        if cfg_logs:get() then
            print("[Resolver] AnimState Error (safe_get_animstate): " .. tostring(result))
        end
        return nil
    end
end

-- Get specific animation layer safely
local function get_layer(layers, index)
    if not layers then
        return nil
    end
    
    local success, result = pcall(function()
        return layers[index]
    end)
    
    if success then
        return result
    else
        if cfg_logs:get() then
            print("[Resolver] Layer access error (get_layer): " .. tostring(result))
        end
        return nil
    end
end

-- Analyze animation layers for jitter patterns
local function analyze_animlayers(player, player_index)
    local layers = safe_get_animlayers(player)
    if not layers then
        return 0
    end
    
    -- Focus on movement and action layers (typically layers 3, 6, 11, 12)
    local layer_3 = get_layer(layers, 3)  -- Movement layer
    local layer_6 = get_layer(layers, 6)  -- Action layer
    local layer_11 = get_layer(layers, 11) -- Lean/strafe layer
    local layer_12 = get_layer(layers, 12) -- Adjust layer
    
    if not layer_3 or not layer_6 or not layer_11 or not layer_12 then
        return 0
    end
    
    local data = resolver_data[player_index]
    
    -- Get animstate for additional data
    local animstate = safe_get_animstate(player)
    local feet_yaw_delta = 0
    
    if animstate then
        local goal_feet_yaw = animstate.flGoalFeetYaw
        local eye_yaw = animstate.flEyeYaw
        feet_yaw_delta = math.abs(goal_feet_yaw - eye_yaw)
    end
    
    -- Store layer history for pattern detection
    table.insert(data.layer_history, {
        weight_3 = layer_3.m_flWeight,
        weight_6 = layer_6.m_flWeight,
        weight_11 = layer_11.m_flWeight,
        weight_12 = layer_12.m_flWeight,
        cycle_3 = layer_3.m_flCycle,
        cycle_11 = layer_11.m_flCycle,
        cycle_12 = layer_12.m_flCycle,
        feet_delta = feet_yaw_delta
    })
    
    -- Keep only last 5 entries
    if #data.layer_history > 5 then
        table.remove(data.layer_history, 1)
    end
    
    -- Calculate correction based on layer weights and cycles
    local correction = 0
    
    -- Analyze layer 11 (lean/strafe) for side detection
    if layer_11.m_flWeight > 0.01 then
        local lean_direction = (layer_11.m_flCycle > 0.5) and 1 or -1
        local lean_strength = layer_11.m_flWeight * 58 -- Increased multiplier for better detection
        correction = correction + (lean_direction * lean_strength)
    end
    
    -- Analyze layer 12 (adjust) for micro-corrections
    if layer_12.m_flWeight > 0.2 then
        local adjust_factor = (layer_12.m_flCycle - 0.5) * 2
        correction = correction + (adjust_factor * 35)
    end
    
    -- Analyze layer 6 for action-based corrections
    if layer_6.m_flWeight > 0.1 then
        local action_delta = math.abs(0.5 - layer_6.m_flCycle) * 2
        correction = correction + (action_delta * 20)
    end
    
    -- Analyze layer 3 movement patterns for jitter detection
    if #data.layer_history >= 3 then
        local curr = data.layer_history[#data.layer_history]
        local prev = data.layer_history[#data.layer_history - 1]
        
        local weight_delta = math.abs(curr.weight_3 - prev.weight_3)
        local cycle_delta = math.abs(curr.cycle_11 - prev.cycle_11)
        
        -- Detect rapid changes indicating jitter
        if weight_delta > 0.15 or cycle_delta > 0.3 then
            data.jitter_detected = true
            data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 10)
            
            -- Alternate correction based on jitter pattern
            if data.consecutive_jitters % 2 == 0 then
                correction = -correction
            end
            
            -- Add extra correction for heavy jitter
            if data.consecutive_jitters > 5 then
                correction = correction * 1.15
            end
        else
            data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
            if data.consecutive_jitters == 0 then
                data.jitter_detected = false
            end
        end
    end
    
    -- Use feet yaw delta for additional correction
    if feet_yaw_delta > 35 then
        local feet_correction = (feet_yaw_delta - 35) * 0.5
        correction = correction + (data.jitter_side * feet_correction)
    end
    
    return correction
end

-- Velocity-based correction
local function get_velocity_correction(player, player_index)
    if not player then
        return 0
    end
    
    local success, velocity = pcall(function()
        return player:get_prop("m_vecVelocity")
    end)
    
    if not success or not velocity then
        return 0
    end
    
    local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    local data = resolver_data[player_index]
    
    -- Detect velocity changes (potential fake)
    local velocity_delta = math.abs(speed - data.last_velocity)
    local old_velocity = data.last_velocity
    data.last_velocity = speed
    
    -- Rapid velocity change detection
    if velocity_delta > 100 then
        -- Sudden velocity change, likely desync
        local correction = (speed > old_velocity) and 30 or -30
        
        -- Adjust based on consecutive jitters
        if data.consecutive_jitters > 3 then
            correction = correction * 1.2
        end
        
        return correction
    end
    
    -- Standing still with jitter = potential static fake
    if speed < 5 and data.jitter_detected then
        return data.consecutive_jitters % 2 == 0 and 45 or -45
    end
    
    return 0
end

-- Main resolver logic
local function resolve_player(player, player_index)
    if not player or player:is_dormant() then
        return
    end
    
    local data = resolver_data[player_index]
    
    local success, result = pcall(function()
        local current_sim_time = player:get_prop("m_flSimulationTime")
        
        -- Check if player updated
        if current_sim_time == data.last_sim_time then
            return false
        end
        
        data.last_sim_time = current_sim_time
        
        -- Get base yaw from animstate
        local animstate = safe_get_animstate(player)
        if not animstate then
            return false
        end
        
        local current_yaw = animstate.flEyeYaw
        
        -- Analyze animation layers for correction
        local layer_correction = analyze_animlayers(player, player_index)
        
        -- Get velocity-based correction
        local velocity_correction = get_velocity_correction(player, player_index)
        
        -- Combine corrections with weighting
        local total_correction = (layer_correction * 0.7) + (velocity_correction * 0.3)
        
        -- Clamp correction to reasonable values
        if total_correction > 60 then
            total_correction = 60
        elseif total_correction < -60 then
            total_correction = -60
        end
        
        -- Apply correction to resolver
        local resolved_yaw = current_yaw + total_correction
        
        -- Normalize angle
        while resolved_yaw > 180 do
            resolved_yaw = resolved_yaw - 360
        end
        while resolved_yaw < -180 do
            resolved_yaw = resolved_yaw + 360
        end
        
        data.resolve_angle = resolved_yaw
        data.last_yaw = current_yaw
        
        -- Determine jitter side for next frame
        if data.jitter_detected then
            data.jitter_side = (total_correction > 0) and 1 or -1
        else
            data.jitter_side = 0
        end
        
        -- Apply resolved angle to player using animstate
        if animstate then
            animstate.flGoalFeetYaw = resolved_yaw
        end
        
        -- Logging
        if cfg_logs:get() then
            local player_name = "Player"
            local success_name, name_result = pcall(function()
                return player:get_name()
            end)
            if success_name and name_result then
                player_name = name_result
            else
                player_name = "ID:" .. tostring(player_index)
            end
            
            local log_msg = string.format(
                "[Resolver] %s | Yaw: %.1f | Corr: %.1f | Jitter: %s | Count: %d",
                tostring(player_name),
                tostring(current_yaw),
                tostring(total_correction),
                tostring(data.jitter_detected),
                tostring(data.consecutive_jitters)
            )
            print(log_msg)
        end
        
        return true
    end)
    
    if not success and cfg_logs:get() then
        print("[Resolver] Error resolving player (resolve_player): " .. tostring(result))
    end
end

-- Main callback - runs every frame
local function on_setup_command(cmd)
    if not cfg_resolver:get() then
        return
    end
    
    local local_player = entity_list.get_local_player()
    if not local_player or not local_player:is_alive() then
        return
    end
    
    -- Resolve all enemy players
    local players = entity_list.get_players(true) -- true = enemies only
    if not players then
        return
    end
    
    for i = 1, #players do
        local success, error_msg = pcall(function()
            local player = players[i]
            if player and player:is_alive() and not player:is_dormant() then
                local player_index = player:get_index()
                if player_index then
                    resolve_player(player, player_index)
                end
            end
        end)
        
        if not success and cfg_logs:get() then
            print("[Resolver] Error in main loop (on_setup_command): " .. tostring(error_msg))
        end
    end
end

-- Reset resolver data on round start
local function on_round_start()
    if cfg_logs:get() then
        print("[Resolver] Round started - resetting resolver data")
    end
    
    for i = 1, MAX_PLAYERS do
        resolver_data[i] = {
            last_yaw = 0,
            last_sim_time = 0,
            jitter_detected = false,
            jitter_side = 0,
            layer_history = {},
            resolve_angle = 0,
            consecutive_jitters = 0,
            last_velocity = 0
        }
    end
end

-- Shutdown cleanup
local function on_shutdown()
    if cfg_logs:get() then
        print("[Resolver] Shutting down - cleaning up")
    end
    
    -- Clear all resolver data
    resolver_data = {}
end

-- Register callbacks
callbacks.add(e_callbacks.SETUP_COMMAND, on_setup_command)
callbacks.add(e_callbacks.EVENT, on_round_start, "round_start")
callbacks.add(e_callbacks.SHUTDOWN, on_shutdown)

-- Initial load message
if cfg_logs:get() then
    print("[Resolver] Jitter Correction Resolver loaded successfully")
end
