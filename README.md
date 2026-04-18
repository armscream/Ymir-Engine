Ymir Engine

Written in the Odin Programming language using Data-Oriented-Design. The intention is to create a fast, modern, 3d game-engine.
Odin is chosen for it's simplicity and for how easy it is to learn compared to other low-level languages. Long-term, this will minimize pain-points for developers,
especially considering comp-time.

Alpha intent: Feature-complete Minimum-Viable-Product for 1.0 release, but not yet polished.
  IOT acheive feature completeness, this is a non-exhaustive set of roadmap 'features' that are desired for the MVP:
  
    Editor -- Full 3d editor
      --- Important Editor features ---
      level and layer hierarchy + selection             - not started
      asset management gui                              - not started
      gizmos                                            - not started
      level + layer editing                             - not started
      material node graph                               - not started
      animation node graph                              - not started
    Scene graph                                         - not started
    Functional Rendering backends                       - doing software renderer ATM
      At least a 3d PBR SDL3 GPU backend                - not started
    Complete level and layer saving with API calls      - in progress, saves and loads basic level data.
    ECS                                                 - Not started, but may just allow for end user to use own.. not sure yet.
    In-game UI system.                                  - not started
    logger                                              - not started
    game-config load/save                               - completed
    controls-config load/save                           - completed
    graphics-settings load/save                         - not started
    window creation/handling                            - completed / at least for software backend.
    asset manager                                       - not started
    job scheduler                                       - not started

    more to follow...

Beta intent: Polished to the point of external developer satisfaction, at least one game shipped IOT exit beta.

Build helper script:

- Use `build_from_game_config.ps1` to compile `App` and name the exe from `App/Config/game.json` `game_name`.
- Output is written to `Build/<game_name>.exe`.
- Example:
  `./build_from_game_config.ps1`
