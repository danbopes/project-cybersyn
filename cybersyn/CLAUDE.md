# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Project Cybersyn is a Factorio mod that creates a feature-rich train logistics network through cybernetic combinators. The mod coordinates economic inputs and outputs across entire megabases using train scheduling algorithms.

## Architecture

The mod follows Factorio's standard mod structure with these key components:

- **Entry Point**: `control.lua` requires all script modules and sets up the mod
- **Core Logic**: Located in `scripts/` directory
  - `central-planning.lua` - Core train scheduling and logistics algorithms
  - `main.lua` - Main game event handlers and depot/station management
  - `train-events.lua` - Train state management and event processing
  - `gui/` - Complete GUI system for managing trains, stations, and logistics
- **Prototypes**: `prototypes/` directory defines game entities, items, and technologies
- **Data Files**: `data.lua`, `data-final-fixes.lua` for game data modifications
- **Localization**: `locale/` with translations in multiple languages

### Key Systems

1. **Central Planning System** (`scripts/central-planning.lua`): Implements sophisticated logistics algorithms using hash-based item tracking with quality support
2. **GUI Manager** (`scripts/gui/main.lua`): Uses flib GUI framework for the management interface
3. **Train Events** (`scripts/train-events.lua`): Handles all train state changes and scheduling
4. **Depot Management** (`scripts/main.lua`): Manages depot creation, assignment, and train routing

## Development

This is a Lua-based Factorio mod. No build, test, or lint commands are available - the mod runs directly in the Factorio game engine.

### File Organization

- Runtime scripts in `scripts/` (loaded via `control.lua`)
- Game data definitions in `prototypes/` (loaded via `data.lua`)
- Graphics assets in `graphics/` subdirectories
- Configuration in `settings.lua` and `info.json`
- Version history in `changelog.txt`

### Dependencies

- Factorio 2.0.34+
- flib 0.15.0+ (GUI framework)
- Optional compatibility with Space Exploration, miniloader, nullius, pypostprocessing

### Mod Compatibility

Compatibility modules in `scripts/mod-compatibility/`:
- `picker-dollies.lua` - Integration with Picker Dollies mod
- `space-exploration.lua` - Space Exploration mod support