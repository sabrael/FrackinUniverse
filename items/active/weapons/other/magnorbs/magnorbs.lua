require "/scripts/vec2.lua"
require "/scripts/util.lua"
require "/scripts/status.lua"
require "/scripts/activeitem/stances.lua"
require "/items/active/weapons/crits.lua"

function init()
	activeItem.setCursor("/cursors/reticle0.cursor")

	self.projectileType = config.getParameter("projectileType")
	self.projectileParameters = config.getParameter("projectileParameters")
	self.projectileParameters.power = self.projectileParameters.power * root.evalFunction("weaponDamageLevelMultiplier", config.getParameter("level", 1))

	self.cooldownTime = config.getParameter("cooldownTime", 0)
	self.cooldownTimer = self.cooldownTime
	self.count = config.getParameter("count", 3)

	initStances()

	storage.projectileIds = storage.projectileIds or {}
	getProjectiles()
	checkProjectiles()

	self.orbitRate = config.getParameter("orbitRate", 1) * -2 * math.pi

	animator.resetTransformationGroup("orbs")
	for i = 1, self.count do
        animator.setAnimationState("orb"..i, storage.projectileIds[i] == false and "orb" or "hidden")
	end
	setOrbPosition(1)

	self.shieldPower = config.getParameter("shieldPower")
	self.shieldEphemeralEffects=config.getParameter("shieldEphemeralEffects")
	self.shieldEphemeralEffectsExist=type(self.shieldEphemeralEffects)=="table"
	self.shieldPersistentEffects=config.getParameter("shieldPersistentEffects")
	self.shieldPersistentEffectsExist=(type(self.shieldPersistentEffects)=="table")
	self.shieldPersistentGroup=config.getParameter("shieldPersistentGroup","magnorbPersistent")
	self.shieldActive = false
	self.shieldTransformTimer = 0

	self.shieldTransformTime = config.getParameter("shieldTransformTime", 0.1)
	self.shieldPoly = animator.partPoly("glove", "shieldPoly")
	self.shieldEnergyCost = config.getParameter("shieldEnergyCost", 50)
	self.shieldHealth = 1000
	self.shieldKnockback = config.getParameter("shieldKnockback", 0)
	if self.shieldKnockback > 0 then
	self.knockbackDamageSource = {
        poly = self.shieldPoly,
        damage = 0,
        damageType = "Knockback",
        sourceEntity = activeItem.ownerEntityId(),
        team = activeItem.ownerTeam(),
        knockback = self.shieldKnockback,
        rayCheck = true,
        damageRepeatTimeout = 0.5
	}
	end

	setStance("idle")
	updateHand()

	-- Race checks
	self.species = world.entitySpecies(activeItem.ownerEntityId())
end

function update(dt, fireMode, shiftHeld)

	self.cooldownTimer = math.max(0, self.cooldownTimer)

	updateStance(dt)
	checkProjectiles()

	if fireMode == "alt" and availableOrbCount() == self.count and not status.resourceLocked("energy") and status.resourcePositive("shieldStamina") then
        if not self.shieldActive then
            activateShield()
            addShieldEffect()
        end
        setOrbAnimationState("shield")
        self.shieldTransformTimer = math.min(self.shieldTransformTime, self.shieldTransformTimer + dt)
		if self.shieldPersistentEffectsExist then
			world.sendEntityMessage(entity.id(),"recordFUPersistentEffect",self.shieldPersistentGroup)
		end
    else
        self.shieldTransformTimer = math.max(0, self.shieldTransformTimer - dt)
        if self.shieldTransformTimer > 0 then
            setOrbAnimationState("unshield")
        end
	end

	if self.shieldTransformTimer == 0 and fireMode == "primary" and self.lastFireMode ~= "primary" and self.cooldownTimer == 0 then
        local nextOrbIndex = nextOrb()
        if nextOrbIndex then
            fire(nextOrbIndex)
        end
    end
	self.lastFireMode = fireMode

	if self.shieldActive then
        if not status.resourcePositive("shieldStamina") or not status.overConsumeResource("energy", self.shieldEnergyCost * dt) then
            deactivateShield()
            removeShieldEffect()
        else
            self.damageListener:update()
        end
    end

	if self.shieldTransformTimer > 0 then
        local transformRatio = self.shieldTransformTimer / self.shieldTransformTime
        setOrbPosition(1 - transformRatio * 0.7, transformRatio * 0.75)
        animator.resetTransformationGroup("orbs")
        animator.translateTransformationGroup("orbs", {transformRatio * -1.5, 0})
	else
        if self.shieldActive then
            deactivateShield()
            removeShieldEffect()
        end

        animator.resetTransformationGroup("orbs")
        animator.rotateTransformationGroup("orbs", -self.armAngle or 0)
        for i = 1, self.count do
            animator.rotateTransformationGroup("orb"..i, self.orbitRate * dt)
            animator.setAnimationState("orb"..i, storage.projectileIds[i] == false and "orb" or "hidden")
        end
    end

	updateAim()
	updateHand()
end

function uninit()
	deactivateShield()
	removeShieldEffect()
	activeItem.setItemShieldPolys()
	activeItem.setItemDamageSources()
	animator.stopAllSounds("shieldLoop")
end

function nextOrb()
	for i = 1, self.count do
        if not storage.projectileIds[i] then
            return i
        end
	end
end

function availableOrbCount()
	local available = 0
	for i = 1, self.count do
        if not storage.projectileIds[i] then
            available = available + 1
        end
    end
	return available
end

function updateHand()
	local isFrontHand = (activeItem.hand() == "primary") == (mcontroller.facingDirection() < 0)
	animator.setGlobalTag("hand", isFrontHand and "front" or "back")
	activeItem.setOutsideOfHand(isFrontHand)
end

function fire(orbIndex)
	local params = copy(self.projectileParameters)
	params.powerMultiplier = activeItem.ownerPowerMultiplier() 

	params.power = Crits.setCritDamage(self, params.power)

	params.ownerAimPosition = activeItem.ownerAimPosition()
	local firePos = firePosition(orbIndex)

	if status.resourcePositive("energy") and not status.resourceLocked("energy") then

		if world.lineCollision(mcontroller.position(), firePos) then return end
		local projectileId = world.spawnProjectile(
            self.projectileType,
            firePosition(orbIndex),
            activeItem.ownerEntityId(),
            aimVector(orbIndex),
            false,
            params
		)
		if projectileId then
            storage.projectileIds[orbIndex] = projectileId
            self.cooldownTimer = self.cooldownTime
            animator.playSound("fire")
		end

        -- FU adds energy drain to these otherwise OP with crit weapons
        self.tempEnergy = (config.getParameter("level", 1) + 7) -- base Magnorb cost
        --self.magnorbBonus = self.tempEnergy * status.stat("magnorbMastery") -- energy cost reduction

        --if status.stat("magnorbMastery") > 0 then
        --	self.energyCost = self.tempEnergy * status.stat("magnorbMastery")
    	--else
    	self.energyCost = self.tempEnergy 
    	--end
        status.overConsumeResource("energy", self.energyCost)

	end
end

function firePosition(orbIndex)
	return vec2.add(mcontroller.position(), activeItem.handPosition(animator.partPoint("orb"..orbIndex, "orbPosition")))
end

function aimVector(orbIndex)
	return vec2.norm(world.distance(activeItem.ownerAimPosition(), firePosition(orbIndex)))
end

function checkProjectiles()
	for i, projectileId in ipairs(storage.projectileIds) do
        if projectileId and not world.entityExists(projectileId) then
            storage.projectileIds[i] = false
        end
	end
end

function activateShield()
	self.shieldActive = true
	animator.resetTransformationGroup("orbs")
	animator.playSound("shieldOn")
	animator.playSound("shieldLoop", -1)
	setStance("shield")
	activeItem.setItemShieldPolys({self.shieldPoly})
	activeItem.setItemDamageSources({self.knockbackDamageSource})
	status.setPersistentEffects("magnorbShield", {{stat = "shieldHealth", amount = self.shieldHealth}})
	self.damageListener = damageListener("damageTaken", function(notifications)
        for _,notification in pairs(notifications) do
            if notification.hitType == "ShieldHit" then
                if status.resourcePositive("shieldStamina") then
                    animator.playSound("shieldBlock")
                else
                    animator.playSound("shieldBreak")
                end
                return
            end
        end
	end)
end

function deactivateShield()
	self.shieldActive = false
	animator.playSound("shieldOff")
	animator.stopAllSounds("shieldLoop")
	setStance("idle")
	activeItem.setItemShieldPolys()
	activeItem.setItemDamageSources()
	status.clearPersistentEffects("magnorbShield")
end

function setOrbPosition(spaceFactor, distance)
	for i = 1, self.count do
        animator.resetTransformationGroup("orb"..i)
        animator.translateTransformationGroup("orb"..i, {distance or 0, 0})
        animator.rotateTransformationGroup("orb"..i, 2 * math.pi * spaceFactor * ((i - 2) / self.count))
	end
end

function setOrbAnimationState(newState)
	for i = 1, self.count do
        animator.setAnimationState("orb"..i, newState)
	end
end

function addShieldEffect()
	if self.shieldEphemeralEffectsExist then
		for _,fx in pairs(self.shieldEphemeralEffects) do
			status.addEphemeralEffect(fx)
		end
	end
	if self.shieldPersistentEffectsExist then
		status.setPersistentEffects(self.shieldPersistentGroup,self.shieldPersistentEffects)
		world.sendEntityMessage(entity.id(),"recordFUPersistentEffect",self.shieldPersistentGroup)
	end
end

function removeShieldEffect()
	if type(self.shieldEphemeralEffects)=="table" then
		for _,fx in pairs(self.shieldEphemeralEffects) do
			status.removeEphemeralEffect(fx)
		end
	end
	if type(self.shieldPersistentEffects)=="table" then
		status.setPersistentEffects(self.shieldPersistentGroup,{})
	end
end

function getProjectiles()
	for i = 1, self.count do
        table.insert(storage.projectileIds, false)
	end
end
