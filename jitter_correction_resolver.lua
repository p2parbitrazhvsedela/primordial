--[[
    Jitter Correction Resolver
    Uses FFI and Animation Layers for accurate enemy yaw resolution
    Static method implementation without mode selection
]]

local ffi = require("ffi")

-- FFI Definitions for Animation Layers
ffi.cdef[[
    typedef struct {
        float m_flCycle;
        float m_flWeight;
        float m_flPlaybackRate;
        float m_flPrevCycle;
        int m_nOrder;
        int m_nSequence;
    } C_AnimationLayer;
]]

-- Configuration UI
local cfg_resolver = ui.add_checkbox("Jitter Correction Resolver")
local cfg_logs = ui.add_checkbox("Resolver Logs")

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
    if not player or not player:is_valid() then
        return nil
    end
    
    local success, result = pcall(function()
        local animstate_ptr = player:get_anim_state()
        if not animstate_ptr then
            return nil
        end
        
        local layers_ptr = player:get_anim_layers()
        if not layers_ptr then
            return nil
        end
        
        return ffi.cast("C_AnimationLayer*", layers_ptr)
    end)
    
    if success then
        return result
    else
        if cfg_logs:get() then
            print("[Resolver] FFI Error at line " .. tostring(debug.getinfo(1).currentline) .. ": " .. tostring(result))
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
            print("[Resolver] Layer access error at line " .. tostring(debug.getinfo(1).currentline) .. ": " .. tostring(result))
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
    
    -- Store layer history for pattern detection
    table.insert(data.layer_history, {
        weight_3 = layer_3.m_flWeight,
        weight_6 = layer_6.m_flWeight,
        weight_11 = layer_11.m_flWeight,
        weight_12 = layer_12.m_flWeight,
        cycle_3 = layer_3.m_flCycle,
        cycle_11 = layer_11.m_flCycle
    })
    
    -- Keep only last 5 entries
    if #data.layer_history > 5 then
        table.remove(data.layer_history, 1)
    end
    
    -- Calculate correction based on layer weights and cycles
    local correction = 0
    
    -- Analyze layer 11 (lean/strafe) for side detection
    if layer_11.m_flWeight > 0 then
        local lean_direction = (layer_11.m_flCycle > 0.5) and 1 or -1
        correction = correction + (lean_direction * layer_11.m_flWeight * 35)
    end
    
    -- Analyze layer 12 (adjust) for micro-corrections
    if layer_12.m_flWeight > 0.3 then
        local adjust_factor = math.abs(layer_12.m_flCycle - 0.5) * 2
        correction = correction + (adjust_factor * 25)
    end
    
    -- Analyze layer 3 movement patterns
    if #data.layer_history >= 3 then
        local weight_delta = math.abs(data.layer_history[#data.layer_history].weight_3 - 
                                      data.layer_history[#data.layer_history - 1].weight_3)
        
        if weight_delta > 0.15 then
            -- Rapid weight change indicates jitter
            data.jitter_detected = true
            data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 10)
            
            -- Invert based on pattern
            if data.consecutive_jitters % 2 == 0 then
                correction = -correction
            end
        else
            data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
            data.jitter_detected = false
        end
    end
    
    return correction
end

-- Velocity-based correction
local function get_velocity_correction(player, player_index)
    if not player or not player:is_valid() then
        return 0
    end
    
    local velocity = player:get_velocity()
    if not velocity then
        return 0
    end
    
    local speed = velocity:length_2d()
    local data = resolver_data[player_index]
    
    -- Detect velocity changes (potential fake)
    local velocity_delta = math.abs(speed - data.last_velocity)
    data.last_velocity = speed
    
    if velocity_delta > 100 then
        -- Sudden velocity change, likely desync
        return (speed > data.last_velocity) and 30 or -30
    end
    
    return 0
end

-- Main resolver logic
local function resolve_player(player, player_index)
    if not player or not player:is_valid() or player:is_dormant() then
        return
    end
    
    -- Don't resolve teammates
    if player:is_teammate() then
        return
    end
    
    local data = resolver_data[player_index]
    local current_sim_time = player:get_simulation_time()
    
    -- Check if player updated
    if current_sim_time == data.last_sim_time then
        return
    end
    
    data.last_sim_time = current_sim_time
    
    -- Get base yaw
    local eye_angles = player:get_eye_angles()
    if not eye_angles then
        return
    end
    
    local current_yaw = eye_angles.y
    
    -- Analyze animation layers for correction
    local layer_correction = analyze_animlayers(player, player_index)
    
    -- Get velocity-based correction
    local velocity_correction = get_velocity_correction(player, player_index)
    
    -- Combine corrections
    local total_correction = layer_correction + velocity_correction
    
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
    
    -- Apply resolved angle to player
    player:set_resolver_angle(resolved_yaw)
    
    -- Logging
    if cfg_logs:get() then
        local log_msg = string.format(
            "[Resolver] Player %d | Yaw: %.1f | Correction: %.1f | Jitter: %s | Side: %d",
            tostring(player_index),
            tostring(current_yaw),
            tostring(total_correction),
            tostring(data.jitter_detected),
            tostring(data.jitter_side)
        )
        print(log_msg)
    end
end

-- Main callback - runs every frame
callbacks.register("createmove", function(cmd)
    if not cfg_resolver:get() then
        return
    end
    
    local local_player = entities.get_local_player()
    if not local_player or not local_player:is_alive() then
        return
    end
    
    -- Resolve all enemy players
    local players = entities.get_players()
    if not players then
        return
    end
    
    for i = 1, #players do
        local success, error_msg = pcall(function()
            local player = players[i]
            if player then
                local player_index = player:get_index()
                if player_index then
                    resolve_player(player, player_index)
                end
            end
        end)
        
        if not success and cfg_logs:get() then
            print("[Resolver] Error at line " .. tostring(debug.getinfo(1).currentline) .. ": " .. tostring(error_msg))
        end
    end
end)

-- Reset resolver data on round start
callbacks.register("round_start", function()
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
end)

if cfg_logs:get() then
    print("[Resolver] Jitter Correction Resolver loaded successfully")
end
