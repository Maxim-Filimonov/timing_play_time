# Playtime Tracker - Detailed Implementation Plan

## Project Overview
A gamified time-tracking app that converts time spent on worthwhile activities into earned "Play Minutes" that can be spent on leisure activities.

## Architecture
Following ADR-0002's microkernel/plugin architecture:
- **Core**: Domain logic for Play Balance computation
- **Time Source Plugin**: Reports elapsed time (initially stubbed, future: Timing MCP)
- **Persistence Plugin**: Stores Activities, Manual Sync, Playtime Used (initially stubbed, future: Fibery MCP)

## Detailed Steps

### Phase 1: Foundation (Steps 1-3)
- [x] Generate Phoenix LiveView project with SQLite
- [x] Create this detailed plan.md
- [x] Start server for live progress visualization
- [x] Replace default home page with gamified static mockup

### Phase 2: Plugin Architecture (Steps 4-9)
- [x] Create TimeSource behaviour module at `lib/timing_play_time/plugins/time_source.ex`
  - Defines `get_elapsed_minutes/2` callback
- [x] Create Persistence behaviour module at `lib/timing_play_time/plugins/persistence.ex`
  - Defines callbacks for Activities, Manual Sync, Playtime Used
- [x] Create stub TimeSource adapter at `lib/timing_play_time/plugins/time_source/stub.ex`
  - Returns hardcoded time entries for development
- [x] Create stub Persistence adapter at `lib/timing_play_time/plugins/persistence/stub.ex`
  - Uses ETS tables for in-memory storage
- [x] Wire up plugins in Application supervision tree

### Phase 3: Core Domain Logic (Steps 10-15)
- [x] Create PlayBalance calculator at `lib/timing_play_time/play_balance.ex`
  - `compute/0` - calculates current balance
  - Timing-derived total + Manual Sync - Playtime Used sum
- [x] Create ActivityManager context at `lib/timing_play_time/activity_manager.ex`
  - Wrapper around Persistence plugin for Activity CRUD
  - `list_activities/0`, `create_activity/1`, etc.
- [x] Create ManualSync context at `lib/timing_play_time/manual_sync.ex`
  - `set_total/1` - overwrites manual sync value
  - `get_total/0` - retrieves current manual sync total
- [x] Create PlaytimeUsed context at `lib/timing_play_time/playtime_used.ex`
  - `log_usage/2` - records play time spent
  - `list_all/0` - retrieves usage history
  - `total_used/0` - sums all usage

### Phase 4: LiveView UI - Gamified Dashboard (Steps 16-17)
- [ ] Create DashboardLive at `lib/timing_play_time_web/live/dashboard_live.ex`
  - Real-time Play Balance display with animated progress bar
  - "Earned" vs "Spent" metrics with celebratory animations
  - Activity list with individual progress bars
  - Quick actions: Log Playtime Used, Manual Sync
  - PubSub for real-time updates across tabs
- [ ] Create dashboard template at `lib/timing_play_time_web/live/dashboard_live.html.heex`
  - Gamified design: progress bars, achievement badges, confetti effects
  - Color-coded balance (green when positive, orange when low)
  - Responsive mobile-first layout
  - Wrapped in `<Layouts.app flash={@flash}>...</Layouts.app>`

### Phase 5: Layout & Design (Steps 18-19)
- [ ] Update `assets/css/app.css` to match gamified theme
  - Bright, playful colors (purples, greens, oranges)
  - Custom daisyUI theme with gamified palette
  - Progress bar animations and transitions
- [ ] Update `lib/timing_play_time_web/components/layouts/root.html.heex`
  - Force theme to "light" for bright, playful design
  - Remove theme switcher
- [ ] Update `lib/timing_play_time_web/components/layouts.ex` 
  - Remove default Phoenix header/nav
  - Add custom app header with play balance widget
  - Keep `<.flash_group>` in app layout

### Phase 6: Router & Final Steps (Steps 20-21)
- [ ] Update router at `lib/timing_play_time_web/router.ex`
  - Remove placeholder `get "/"` route
  - Add `live "/", DashboardLive` as root route
- [ ] Visit app with `web http://localhost:4000` to verify everything works

## Design Choices
- **Gamified & Playful**: Progress bars, achievement badges, confetti animations
- **Color Palette**: Vibrant purples (#8B5CF6), greens (#10B981), oranges (#F59E0B)
- **Typography**: Rounded, friendly fonts with playful sizing
- **Interactions**: Celebrate milestones, animate balance changes, pulse when earning

## Future Enhancements (Not in this plan)
- Real MCP adapters for Timing and Fibery
- Achievement system with unlockables
- Historical charts and analytics
- Balance cap (mentioned in CONTEXT.md)

## Reserved Steps
- 1 step reserved for debugging and unexpected issues

