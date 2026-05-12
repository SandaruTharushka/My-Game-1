--!strict

local Types = require(script.Parent.Parent.Types)

-- Role registry. Add new roles here; RoleService picks them up automatically.
-- maxConcurrentPlayers = nil means no cap.

local RoleConfig: { [string]: Types.RoleDefinition } = {
	civilian = {
		id = "civilian",
		displayName = "Civilian",
		description = "Live freely in the city.",
		permissions = {
			canArrest = false,
			canHeal = false,
			canAccessShop = true,
			canRepairVehicles = false,
			maxActiveVehicles = 1,
		},
		payRatePerMinute = 5,
		maxConcurrentPlayers = nil,
	},

	police = {
		id = "police",
		displayName = "Police Officer",
		description = "Protect and serve the citizens.",
		permissions = {
			canArrest = true,
			canHeal = false,
			canAccessShop = true,
			canRepairVehicles = false,
			maxActiveVehicles = 1,
		},
		payRatePerMinute = 12,
		maxConcurrentPlayers = 8,
	},

	medic = {
		id = "medic",
		displayName = "Paramedic",
		description = "Respond to medical emergencies.",
		permissions = {
			canArrest = false,
			canHeal = true,
			canAccessShop = true,
			canRepairVehicles = false,
			maxActiveVehicles = 1,
		},
		payRatePerMinute = 10,
		maxConcurrentPlayers = 6,
	},

	retail = {
		id = "retail",
		displayName = "Retail Worker",
		description = "Staff the city's shops and stores.",
		permissions = {
			canArrest = false,
			canHeal = false,
			canAccessShop = true,
			canRepairVehicles = false,
			maxActiveVehicles = 1,
		},
		payRatePerMinute = 8,
		maxConcurrentPlayers = nil,
	},

	mechanic = {
		id = "mechanic",
		displayName = "Mechanic",
		description = "Keep the city's vehicles running.",
		permissions = {
			canArrest = false,
			canHeal = false,
			canAccessShop = true,
			canRepairVehicles = true,
			maxActiveVehicles = 1,
		},
		payRatePerMinute = 10,
		maxConcurrentPlayers = 4,
	},
}

return RoleConfig
