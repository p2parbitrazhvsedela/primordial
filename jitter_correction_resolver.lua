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
        last_lby = 0,
        last_lby_update = 0,
        last_sim_time = 0,
        jitter_detected = false,
        jitter_side = 0,
        layer_history = {},
        resolve_angle = 0,
        consecutive_jitters = 0,
        last_velocity = 0,
        miss_count = 0,
        brute_phase = 0,
        was_standing = false,
        last_duck = 0
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

-- Get eye yaw from prop
local function get_eye_yaw(player)
    if not player then
        return nil
    end
    
    local success, result = pcall(function()
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

-- Normalize angle to -180..180
local function normalize_angle(angle)
    while angle > 180 do
        angle = angle - 360
    end
    while angle < -180 do
        angle = angle + 360
    end
    return angle
end

-- Get duck amount
local function get_duck_amount(player)
    if not player then
        return 0
    end
    
    local success, result = pcall(function()
        return player:get_prop("m_flDuckAmount")
    end)
    
    return (success and result) or 0
end

-- Check if player is standing still
local function is_standing(player)
    if not player then
        return false
    end
    
    local success, velocity = pcall(function()
        return player:get_prop("m_vecVelocity")
    end)
    
    if not success or not velocity then
        return false
    end
    
    local speed = math.sqrt(velocity.x * velocity.x + velocity.y * velocity.y)
    return speed < 5
end

-- Analyze player for jitter patterns using props
local function analyze_jitter(player, player_index)
    if not player then
        return 0
    end
    
    local data = resolver_data[player_index]
    
    -- Get current state
    local current_yaw = get_eye_yaw(player)
    local lby = get_lby(player)
    local duck_amount = get_duck_amount(player)
    local standing = is_standing(player)
    
    if not current_yaw or not lby then
        return 0
    end
    
    -- Calculate yaw delta (desync amount)
    local yaw_delta = normalize_angle(current_yaw - lby)
    local abs_delta = math.abs(yaw_delta)
    
    -- Detect LBY update
    local lby_updated = math.abs(lby - data.last_lby) > 5
    if lby_updated then
        data.last_lby_update = global_vars.cur_time()
        data.last_lby = lby
    end
    
    -- Store history for pattern detection
    table.insert(data.layer_history, {
        yaw = current_yaw,
        lby = lby,
        delta = abs_delta,
        delta_signed = yaw_delta,
        standing = standing,
        duck = duck_amount,
        time = global_vars.cur_time()
    })
    
    -- Keep only last 6 entries for better pattern analysis
    if #data.layer_history > 6 then
        table.remove(data.layer_history, 1)
    end
    
    local correction = 0
    
    -- Need at least 3 frames for analysis
    if #data.layer_history >= 3 then
        local curr = data.layer_history[#data.layer_history]
        local prev = data.layer_history[#data.layer_history - 1]
        local prev2 = data.layer_history[#data.layer_history - 2]
        
        -- Calculate yaw change rate
        local yaw_change = math.abs(curr.yaw - prev.yaw)
        local yaw_change2 = math.abs(prev.yaw - prev2.yaw)
        
        -- Detect side flips (jitter indicator)
        local side_flip = (curr.delta_signed * prev.delta_signed) < 0
        local side_flip2 = (prev.delta_signed * prev2.delta_signed) < 0
        
        -- Calculate time since LBY update
        local lby_age = global_vars.cur_time() - data.last_lby_update
        
        -- Detect jitter by multiple indicators
        local is_jittering = (yaw_change > 30 or yaw_change2 > 30) or (side_flip and side_flip2)
        
        if is_jittering then
            data.jitter_detected = true
            data.consecutive_jitters = math.min(data.consecutive_jitters + 1, 15)
            
            -- Apply brute force if too many misses
            if data.miss_count > 2 then
                data.brute_phase = (data.brute_phase + 1) % 3
                
                if data.brute_phase == 0 then
                    correction = 60 -- Right
                elseif data.brute_phase == 1 then
                    correction = -60 -- Left
                else
                    correction = 0 -- Center
                end
            else
                -- Smart resolution based on patterns
                if curr.standing or standing then
                    -- Standing player - check LBY update timing
                    if lby_age > 1.1 then
                        -- LBY is about to update, resolve to current side
                        correction = curr.delta_signed > 0 and abs_delta or -abs_delta
                    else
                        -- LBY fresh, resolve opposite
                        correction = curr.delta_signed > 0 and -58 or 58
                    end
                else
                    -- Moving player - resolve based on desync side
                    if abs_delta > 35 then
                        -- High desync
                        local side = curr.delta_signed > 0 and -1 or 1
                        correction = side * 58
                        
                        -- Alternate for heavy jitter
                        if data.consecutive_jitters > 5 then
                            if data.consecutive_jitters % 2 == 0 then
                                correction = -correction
                            end
                        end
                    else
                        -- Low desync
                        correction = data.consecutive_jitters % 2 == 0 and 50 or -50
                    end
                end
            end
        else
            -- No jitter detected - decay counter
            data.consecutive_jitters = math.max(data.consecutive_jitters - 1, 0)
            if data.consecutive_jitters == 0 then
                data.jitter_detected = false
                data.miss_count = 0 -- Reset miss counter when stable
            end
            
            -- Soft correction based on desync and state
            if abs_delta > 35 then
                if standing then
                    -- Standing with high desync - predictive correction
                    if lby_age > 0.8 then
                        correction = curr.delta_signed * 0.9
                    else
                        correction = -curr.delta_signed * 0.85
                    end
                else
                    -- Moving with desync
                    local side = curr.delta_signed > 0 and -1 or 1
                    correction = side * (abs_delta * 0.75)
                end
            elseif abs_delta > 15 then
                -- Medium desync - light correction
                correction = -curr.delta_signed * 0.5
            end
        end
    end
    
    -- Store state changes
    data.was_standing = standing
    data.last_duck = duck_amount
    
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
    
    -- Detect velocity changes
    local velocity_delta = math.abs(speed - data.last_velocity)
    local old_velocity = data.last_velocity
    data.last_velocity = speed
    
    local correction = 0
    
    -- Rapid velocity change detection (potential slowwalk fake)
    if velocity_delta > 80 then
        correction = (speed > old_velocity) and 25 or -25
        
        -- Boost correction if jittering
        if data.consecutive_jitters > 3 then
            correction = correction * 1.3
        end
    end
    
    -- Standing with jitter - more aggressive
    if speed < 5 and data.jitter_detected then
        if data.consecutive_jitters > 7 then
            -- Heavy jitter while standing
            correction = data.consecutive_jitters % 2 == 0 and 52 or -52
        else
            correction = data.consecutive_jitters % 2 == 0 and 40 or -40
        end
    end
    
    -- Slowwalking detection (34-68 speed range)
    if speed > 34 and speed < 68 and data.jitter_detected then
        correction = correction + (data.consecutive_jitters % 2 == 0 and 15 or -15)
    end
    
    return correction
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
            
            -- Get LBY for logging
            local lby = get_lby(player)
            local desync = lby and math.floor(math.abs(current_yaw - lby)) or 0
            
            local log_msg = string.format(
                "[Resolver] %s | Yaw: %.1f→%.1f | Desync: %d° | Mode: %s | Miss: %d",
                tostring(player_name),
                tostring(current_yaw),
                tostring(resolved_yaw),
                tostring(desync),
                data.jitter_detected and (data.miss_count > 2 and "BRUTE" or "JITTER") or "SOFT",
                tostring(data.miss_count)
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

-- Handle aimbot miss for adaptive resolving
local function on_aimbot_miss(miss)
    if not cfg_resolver:get() then
        return
    end
    
    local player_index = miss.player:get_index()
    if not player_index then
        return
    end
    
    local data = resolver_data[player_index]
    if not data then
        return
    end
    
    -- Increment miss counter
    data.miss_count = math.min(data.miss_count + 1, 5)
    
    if cfg_logs:get() then
        print(string.format("[Resolver] Miss detected on player %d (Total: %d)", 
            tostring(player_index), 
            tostring(data.miss_count)))
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
            last_lby = 0,
            last_lby_update = 0,
            last_sim_time = 0,
            jitter_detected = false,
            jitter_side = 0,
            layer_history = {},
            resolve_angle = 0,
            consecutive_jitters = 0,
            last_velocity = 0,
            miss_count = 0,
            brute_phase = 0,
            was_standing = false,
            last_duck = 0
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
callbacks.add(e_callbacks.AIMBOT_MISS, on_aimbot_miss)
callbacks.add(e_callbacks.EVENT, on_round_start, "round_start")
callbacks.add(e_callbacks.SHUTDOWN, on_shutdown)

-- Initial load message
print("[Resolver] Jitter Correction Resolver v2.0 loaded")
print("[Resolver] Features: LBY timing, brute force, adaptive learning")
if cfg_logs:get() then
    print("[Resolver] Debug logs enabled")
end
