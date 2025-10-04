--[[
    Jitter Correction Resolver
    Advanced enemy yaw resolution using desync analysis
    Static method implementation without mode selection
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

-- Get lower body yaw target
local function get_lby(player)
    if not player then
        return nil
    end
    
    local success, result = pcall(function()
        return player:get_prop("m_flLowerBodyYawTarget")
    end)
    
    if success and result then
        return result
    else
        return nil
    end
end

-- Get eye yaw from prop (backup method)
local function get_eye_yaw(player)
    if not player then
        return nil
    end
    
    local success, result = pcall(function()
        -- Try to get eye angles from prop
        local angles = player:get_prop("m_angEyeAngles")
        if angles then
            return angles.y
        end
        return nil
    end)
    
    if success and result then
        return result
    else
        return nil
    end
end

-- Analyze player for jitter patterns using props
local function analyze_jitter(player, player_index)
    if not player then
        return 0
    end
    
    local data = resolver_data[player_index]
    
    -- Get current yaw and LBY
    local current_yaw = get_eye_yaw(player)
    local lby = get_lby(player)
    
    if not current_yaw or not lby then
        return 0
    end
    
    -- Calculate yaw delta (desync amount)
    local yaw_delta = math.abs(current_yaw - lby)
    while yaw_delta > 180 do
        yaw_delta = yaw_delta - 360
    end
    yaw_delta = math.abs(yaw_delta)
    
    -- Store history for pattern detection
    table.insert(data.layer_history, {
        yaw = current_yaw,
        lby = lby,
        delta = yaw_delta,
        time = global_vars.cur_time()
    })
    
    -- Keep only last 5 entries
    if #data.layer_history > 5 then
        table.remove(data.layer_history, 1)
    end
    
    local correction = 0
    
    -- Analyze history for jitter patterns
    if #data.layer_history >= 3 then
        local curr = data.layer_history[#data.layer_history]
        local prev = data.layer_history[#data.layer_history - 1]
        local prev2 = data.layer_history[#data.layer_history - 2]
        
        -- Calculate yaw change rate
        local yaw_change = math.abs(curr.yaw - prev.yaw)
        local yaw_change2 = math.abs(prev.yaw - prev2.yaw)
        
        -- Detect jitter by rapid yaw changes
        if yaw_change > 35 or yaw_change2 > 35 then
            data.jitter_detected = true
            data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 10)
            
            -- Determine side based on yaw delta
            if curr.delta > 35 then
                -- High desync, resolve to opposite side
                local side = (curr.yaw - curr.lby) > 0 and -1 or 1
                correction = side * 60
                
                -- Alternate if jittering heavily
                if data.consecutive_jitters > 4 then
                    if data.consecutive_jitters % 2 == 0 then
                        correction = -correction
                    end
                end
            else
                -- Low desync, likely fake standing
                correction = data.consecutive_jitters % 2 == 0 and 45 or -45
            end
        else
            -- No rapid changes, decay jitter counter
            data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
            if data.consecutive_jitters == 0 then
                data.jitter_detected = false
            end
            
            -- Apply soft correction based on desync
            if yaw_delta > 35 then
                local side = (curr.yaw - curr.lby) > 0 and -1 or 1
                correction = side * (yaw_delta * 0.8)
            end
        end
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
        
        -- Get base yaw from eye angles prop
        local current_yaw = get_eye_yaw(player)
        if not current_yaw then
            return false
        end
        
        -- Analyze jitter patterns for correction
        local jitter_correction = analyze_jitter(player, player_index)
        
        -- Get velocity-based correction
        local velocity_correction = get_velocity_correction(player, player_index)
        
        -- Combine corrections with weighting (jitter is more important)
        local total_correction = (jitter_correction * 0.75) + (velocity_correction * 0.25)
        
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
        
        -- Store resolved angle for this player
        data.resolved_yaw = resolved_yaw
        
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
