# My Game — City Roleplay Prototype

A server-authoritative Roblox city roleplay foundation built with
[Rojo](https://github.com/rojo-rbx/rojo) and structured Luau modules.

---

## Running with Rojo

### Prerequisites

- [Rojo CLI](https://rojo.space/docs/installation/) ≥ 7.0
- Roblox Studio

### Build once (no live-sync)

```bash
rojo build -o "MyGame.rbxlx"
```

Open `MyGame.rbxlx` in Roblox Studio and press **Play** (or **Start Server**).

### Live-sync during development

1. Start the Rojo dev server:

   ```bash
   rojo serve
   ```

2. Open Roblox Studio → **Plugins → Rojo → Connect**.
3. Press **Play** in Studio — changes on disk sync live into the session.

---

## Project structure

```
src/
  server/
    init.server.luau          ← bootstrap (boot order: Remotes → Map → Profile → Role → lifecycle)
    Services/
      MapService.luau         ← generates the city map on server start
      ProfileService.luau     ← DataStore with session-lock, schema migration, autosave
      RoleService.luau        ← role change validation, concurrency caps, rate limiting
  client/
    init.client.luau          ← bootstrap (remotes, HUD init, profile fetch)
    UI/
      RoleHUD.luau            ← ScreenGui: status bar, role buttons, toast notifications
  shared/
    Config/
      GameConfig.luau         ← all tunable constants (AUTOSAVE_INTERVAL, SALARY_INTERVAL, …)
      RoleConfig.luau         ← role definitions (pay rate, permissions, player cap)
    Network/
      Remotes.luau            ← single source of truth for all RemoteEvents/Functions
    Types.luau                ← shared type exports
    Util/
      Logger.luau             ← structured, level-filtered logger
      RateLimiter.luau        ← per-player sliding-window rate limiter
      Maid.luau               ← connection cleanup helper
```

---

## How the city map is generated

`MapService.init()` runs on every server start and is **idempotent** — it
deletes any existing `Workspace/GeneratedMap` folder before creating a new one.

Everything is built from Roblox `Part` instances (no external assets or
models required), so the map is visible immediately in Studio **Play** mode
without any additional setup.

### What is generated

| Element | Details |
|---|---|
| Roads | Two crossing roads (horizontal + vertical, 16 studs wide) |
| Sidewalks | 4-stud concrete strips alongside each road |
| Grass patches | Four large grass tiles filling the corner quadrants |
| Spawn plaza | Central paved area with a decorative fountain |
| Police Station | North-west quadrant, blue roof |
| Hospital | North-east quadrant, white roof |
| Mechanic Garage | South-west quadrant, brown roof |
| Retail Shop | South-east quadrant, orange roof |
| 4 Residential houses | One per quadrant |
| Bank / Office | South-east, tall dark building |
| Diner | South-west |

Each building has walls, a roof, a door, two windows, and a sign with a
`SurfaceGui` label.

---

## Current features

- **Server-authoritative data** — all coin and role mutations happen server-side only.
- **Persistent profiles** — DataStore with session-locking and schema migration.
- **Role system** — five roles (Civilian, Police, Medic, Retail, Mechanic) with
  per-role concurrency caps and rate-limited change requests.
- **Salary loop** — server pays `payRatePerMinute` coins every 60 seconds per role.
- **Role HUD** — on-screen display of current role and coin balance, plus five
  role-selection buttons.
- **Toast notifications** — slide-in/slide-out visual toasts for server messages
  (salary paid, role changed, errors).
- **Remote validation** — all server remote handlers validate payload types and
  ranges before acting.

---

## Planned next features

- Vehicle spawning with role-gated access (Police car, Ambulance, Tow truck).
- Property/house ownership and door locks.
- NPC pedestrians on the sidewalks.
- Crime and arrest system (Police ↔ Civilian interaction).
- Healing mechanic (Medic heals injured players).
- Admin panel for server operators.
- Sound effects and ambient city audio.
