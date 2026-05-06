# Add a new module to this project

## Task
Create a new ZigModu module. The module should follow the standard structure:
- `module.zig` — declaration layer (info, init, deinit)
- `model.zig` — data structures
- `persistence.zig` — ORM repositories  
- `service.zig` — business logic
- `api.zig` — HTTP routes
- `root.zig` — barrel exports
- `test.zig` — tests
- `_ai.zig` — AI context index

## Context
- Read `_ai.zig` in sibling modules for the pattern
- Read `AGENTS.md` for framework conventions
- Read `src/modules/<existing_module>/_ai.zig` for the AI context format

## Steps
1. Create `src/modules/<name>/` directory
2. Generate all files following the module template
3. Add the module to `src/main.zig` scanModules call
4. Run `zig build test` to verify
