--[[
    Ultimate Resolver v5.0
    Maximum accuracy with minimal complexity
    Focus: Perfect jitter resolution
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
local cfg_enable = menu.add_checkbox("Ultimate Resolver", "Enable", false)
local cfg_logs = menu.add_checkbox("Ultimate Resolver", "Logs", false)

-- Data
local data = {}
for i = 1, 65 do
    data[i] = {last_yaw = 0, last_desync = 0}
end

-- Normalize
local function norm(angle)
    while angle > 180 do angle = angle - 360 end
    while angle < -180 do angle = angle + 360 end
    return angle
end

-- Get animstate
local function get_animstate(player)
    local ok, result = pcall(function()
        local ptr = GetEntity(player:get_index())
        if not ptr then return nil end
        return ffi.cast("struct CAnimstate**", ptr + 0x9960)[0]
    end)
    return ok and result or nil
end

-- Main resolver
local function resolve(player)
    if not player or player:is_dormant() then return end
    
    local anim = get_animstate(player)
    if not anim then return end
    
    local idx = player:get_index()
    local d = data[idx]
    
    -- Read
    local eye = anim.m_flEyeYaw
    local feet = anim.m_flGoalFeetYaw
    local speed = anim.m_flSpeed2D
    local lean = anim.m_flLeanAmount
    local stopped = anim.m_flTimeSinceStoppedMoving or 0
    
    -- Desync
    local desync = norm(eye - feet)
    local abs_desync = math.abs(desync)
    
    -- Detect jitter
    local yaw_change = math.abs(eye - d.last_yaw)
    local desync_flip = (desync * d.last_desync) < 0
    local is_jitter = yaw_change > 35 or (yaw_change > 25 and desync_flip)
    
    d.last_yaw = eye
    d.last_desync = desync
    
    local correction = 0
    local mode = "NONE"
    
    if is_jitter then
        -- JITTER MODE
        mode = "JITTER"
        
        if speed < 5 then
            -- Standing jitter
            if abs_desync > 35 then
                if stopped > 1.05 and stopped < 1.25 then
                    -- LBY updating soon
                    correction = desync
                    mode = "JIT-LBY"
                else
                    -- Resolve opposite
                    correction = desync > 0 and -58 or 58
                    
                    -- Add lean
                    if math.abs(lean) > 0.35 then
                        correction = correction + (lean > 0 and 12 or -12)
                    end
                end
            else
                -- Lower desync
                correction = desync > 0 and -50 or 50
            end
        else
            -- Moving jitter
            if abs_desync > 35 then
                correction = desync > 0 and -58 or 58
                
                -- Lean is important when moving
                if math.abs(lean) > 0.3 then
                    correction = correction + (lean > 0 and 15 or -15)
                end
            else
                correction = desync > 0 and -52 or 52
            end
        end
    else
        -- SOFT MODE
        mode = "SOFT"
        
        if abs_desync > 40 then
            correction = desync > 0 and -(abs_desync * 0.9) or (abs_desync * 0.9)
        elseif abs_desync > 25 then
            correction = desync > 0 and -35 or 35
        elseif abs_desync > 12 then
            correction = desync > 0 and -20 or 20
        end
    end
    
    -- Apply
    local resolved = norm(eye + correction)
    anim.m_flGoalFeetYaw = resolved
    
    -- Log
    if cfg_logs:get() and is_jitter then
        local name = "?"
        pcall(function() name = player:get_name() end)
        print(string.format("[R] %s | %.0f→%.0f | D:%d | %s | C:%d", 
            name, eye, resolved, math.floor(abs_desync), mode, math.floor(correction)))
    end
end

-- Callback
callbacks.add(e_callbacks.NET_UPDATE, function()
    if not cfg_enable:get() then return end
    
    local lp = entity_list.get_local_player()
    if not lp or not lp:is_alive() then return end
    
    local enemies = entity_list.get_players(true)
    if not enemies then return end
    
    for _, p in pairs(enemies) do
        if p and p:is_alive() and not p:is_dormant() then
            pcall(resolve, p)
        end
    end
end)

callbacks.add(e_callbacks.EVENT, function()
    for i = 1, 65 do
        data[i] = {last_yaw = 0, last_desync = 0}
    end
end, "round_start")

print("=================================")
print("Ultimate Resolver v5.0 loaded")
print("Maximum accuracy, minimal code")
print("=================================")
