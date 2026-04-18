package ye

// High-level error surface for the proprietary YMIR ECS API.
// Keep this compact and stable so gameplay code can switch on explicit outcomes.
ECS_Error :: enum {
	// Operation succeeded.
	None,
	// The requested database name is missing from engine.Databases.
	Database_Not_Found,
	// The database reached its current entities_cap limit.
	Database_Full,
	// The entity does not exist or the generation does not match.
	Entity_Not_Found,
	// Placeholder return for APIs intentionally left unimplemented.
	Not_Implemented,
}

// Public entity handle.
// index points into your entity storage, generation protects against stale IDs.
Entity_ID :: struct {
	index: int,
	generation:   u32,
}

// Query state placeholder.
// TODO: expand with query cursor state, archetype/table matches, and optional filters.
Query :: struct {
	db_name: string,
}


// One database in the proprietary ECS.
// Current implementation only tracks capacity and alive IDs.
// TODO: add component storage, archetype/table data, free-list reuse, and versioning.
ECS_Database :: struct {
	// Max entity count currently allowed in this database.
	entities_cap: int,
	// Monotonic counter used for provisional entity index allocation.
	// TODO: replace with free-list recycling for destroyed slots.
	next_entity_index: int,
	// Tracks alive entity generations by entity index.
	// Key: entity index, Value: generation.
	alive_entities: map[int]u32,
}

// Engine-wide ECS root handle, keyed by database name.
// Example names: "gameplay", "editor".
ECS :: struct {
	Databases: map[string]^ECS_Database,
}

// Resolve database by name.
// Returns (db, true) when found, (nil, false) otherwise.
ecs_get_database :: proc(engine: ^ECS, db_name: string) -> (^ECS_Database, bool) {
	if engine == nil {
		return nil, false
	}

	db, ok := engine.Databases[db_name]
	if !ok {
		return nil, false
	}

	return db, true
}

// Create a new entity in a named database.
// Current behavior: monotonic index allocation, generation set to 1.
// TODO: use generation bumping when reusing destroyed indices.
ecs_create_entity :: proc(engine: ^ECS, db_name: string) -> (Entity_ID, ECS_Error) {
	db, ok := ecs_get_database(engine, db_name)
	if !ok {
		return Entity_ID{}, .Database_Not_Found
	}

	if db.alive_entities == nil {
		db.alive_entities = make(map[int]u32)
	}

	if db.next_entity_index >= db.entities_cap {
		return Entity_ID{}, .Database_Full
	}

	eid := Entity_ID{index = db.next_entity_index, generation = 1}
	db.alive_entities[eid.index] = eid.generation
	db.next_entity_index += 1

	return eid, .None
}

// Destroy an entity if the incoming ID still matches the tracked generation.
// TODO: after removing, push index into a reusable free list.
ecs_destroy_entity :: proc(engine: ^ECS, db_name: string, eid: Entity_ID) -> ECS_Error {
	db, ok := ecs_get_database(engine, db_name)
	if !ok {
		return .Database_Not_Found
	}

	gen, exists := db.alive_entities[eid.index]
	if !exists || gen != eid.generation {
		return .Entity_Not_Found
	}

	delete_key(&db.alive_entities, eid.index)
	return .None
}

// Fast validity check for a public entity handle.
ecs_is_entity_alive :: proc(engine: ^ECS, db_name: string, eid: Entity_ID) -> bool {
	db, ok := ecs_get_database(engine, db_name)
	if !ok {
		return false
	}

	gen, exists := db.alive_entities[eid.index]
	return exists && gen == eid.generation
}

// Component API stubs (replace with your real component storage).
// Suggested next step:
// 1) add map[typeid]rawptr table registry or archetype chunks per db
// 2) index by entity index
// 3) validate entity is alive before mutation
ecs_add_component :: proc(engine: ^ECS, db_name: string, eid: Entity_ID, component: $T) -> ECS_Error {
	_ = engine
	_ = db_name
	_ = eid
	_ = component
	return .Not_Implemented
}

ecs_remove_component :: proc(engine: ^ECS, db_name: string, eid: Entity_ID, $T: typeid) -> ECS_Error {
	_ = engine
	_ = db_name
	_ = eid
	return .Not_Implemented
}

// Returns pointer to component storage once implemented.
// Current result is always (nil, .Not_Implemented).
ecs_get_component :: proc(engine: ^ECS, db_name: string, eid: Entity_ID, $T: typeid) -> (^T, ECS_Error) {
	_ = engine
	_ = db_name
	_ = eid
	return nil, .Not_Implemented
}

// Query API stubs.
// Suggested next step:
// 1) define include/exclude component type sets
// 2) materialize candidate entity list at begin
// 3) iterate with cursor in query_next
ecs_query_begin :: proc(query: ^Query, db_name: string) -> ECS_Error {
	if query == nil {
		return .Not_Implemented
	}
	query.db_name = db_name
	return .Not_Implemented
}

ecs_query_next :: proc(query: ^Query) -> (Entity_ID, bool) {
	_ = query
	return Entity_ID{}, false
}
