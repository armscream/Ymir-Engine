// Engine/src/Core/scheduler.odin
//
// Shared scheduler ABI surface. Lives in Core so the engine and every
// module can speak the same System_Entry / Scheduler_Service layout
// without taking a package dependency on BF_DAG.
//
// BF_DAG imports these types from Core. The engine (in Core) constructs
// []System_Entry from every loaded module's registration.systems and
// hands the slice to the BF_DAG Scheduler_Service via rawptr.
package Core

import "core:mem"

// ============================================================================
// SYSTEM STAGE + ACCESS MASKS
// ============================================================================

System_Stage :: enum u32 {
	PreStartup  = 0,
	Startup     = 1,
	PostStartup = 2,
	PreUpdate   = 3,
	Update      = 4,
	PostUpdate  = 5,
	PreRender   = 6,
	Render      = 7,
	PostRender  = 8,
	EndOfFrame  = 9,
}

System_ID :: distinct u32

System_Info :: struct {
	read_mask:  Access_Mask,
	write_mask: Access_Mask,
	stage:      System_Stage,
}

//* SYSTEM ENTRY
//
// System_Entry is the scheduler-side view of a registered system. The
// engine collects these from each module's registration.systems during
// scheduler_build(). The engine assigns `id` sequentially as it walks
// the module list — the scheduler later uses these IDs as stable
// identifiers across a recompile.

System_Entry :: struct {
	info:     System_Info,
	id:       System_ID,
	name:     string,
	callback: proc(_: rawptr),
}

System_Dependency :: struct {
	before: System_ID,
	after:  System_ID,
}

//* OPAQUE HANDLES
World_Handle :: struct {
	ptr: rawptr,
}
Engine_Handle :: struct {
	ptr: rawptr,
}

//* FRAME CONTEXT
// Scheduler_Frame is the per-frame context that flows into every
// system's callback as a rawptr. Systems cast it back to
// ^Scheduler_Frame to read the world, engine, dt, and frame_index.
Scheduler_Frame :: struct {
	world:       World_Handle,
	engine:      Engine_Handle,
	dt:          f32,
	frame_index: u64,
}

//* SYSTEM EXECUTION CONTEXT
// This is created by the scheduler for each system invocation.
//
// `worker_id` is the worker that ACTUALLY claimed/executed the DAG node.
// It must not be confused with Frame_DAG.owner_worker or preferred_worker.
//
// The context is execution-local and must not be retained by a system.
// Execution-local state supplied by BF_DAG.
Scheduler_System_Context :: struct {
	frame:     ^Scheduler_Frame,
	worker_id: int,
}

//* SCHEDULER SERVICE VTABLE
//
// Scheduler_Service is the vtable the engine calls into once all modules
// have registered their systems. Registered under the service name
// "BF_DAG.Scheduler" by the BF_DAG module.
//
// All procs take ^Scheduler_Service rather than rawptr so BF_DAG's
// implementation can recover the typed vtable from `service.instance`.
// Cross-ABI data (System_Entry slice, Scheduler_Frame) is passed as
// rawptr + length — both ends agree on the layout because the types
// live here in Core.
Scheduler_Service :: struct {
	instance:      rawptr,
	// build compiles a Frame_DAG from the systems the engine gathered
	// from every loaded module.
	//   systems_ptr / systems_count : []System_Entry
	//   deps_ptr / deps_count       : []System_Dependency
	// The caller owns the slices; the service does NOT free them.
	build:         proc(
		service: ^Scheduler_Service,
		systems_ptr: rawptr,
		systems_count: int,
		deps_ptr: rawptr,
		deps_count: int,
		allocator: mem.Allocator,
	) -> bool,
	// begin_frame resets per-frame runtime state and enqueues root nodes.
	// frame_ptr points at a caller-owned Scheduler_Frame whose storage
	// must outlive the matching wait() call.
	begin_frame:   proc(service: ^Scheduler_Service, frame_ptr: rawptr),
	// run drains the DAG on the calling (main) thread.
	run:           proc(service: ^Scheduler_Service),
	// wait blocks the calling thread until every worker (including
	// the main worker that ran `run`) has finished the current frame.
	wait:          proc(service: ^Scheduler_Service),
	// start_workers spawns the worker thread pool. Must be called
	// after build() and before the first begin_frame().
	start_workers: proc(service: ^Scheduler_Service),
	// destroy tears the scheduler down. Called by the service registry
	// via Service_Registration.destroy.
	destroy:       proc(service: ^Scheduler_Service),
	worker_count:  proc(service: ^Scheduler_Service) -> int,
}

//* HELPERS
scheduler_service_worker_count :: proc(service: ^Scheduler_Service) -> int {
	if service == nil || service.worker_count == nil do return 0
	return service.worker_count(service)
}

//* ACCESS MASKS
ACCESS_MASK_WORD_BITS :: 64
ACCESS_MASK_WORD_COUNT :: 4
ACCESS_MASK_CAPACITY :: ACCESS_MASK_WORD_BITS * ACCESS_MASK_WORD_COUNT

Access_Mask :: struct {
	words: [ACCESS_MASK_WORD_COUNT]u64,
}

access_mask_empty :: #force_inline proc() -> Access_Mask {
	return {}
}

access_mask_from_bit :: #force_inline proc(bit_index: u32) -> Access_Mask {
	assert(bit_index < ACCESS_MASK_CAPACITY, "Access mask bit index exceeds capacity")

	mask := Access_Mask{}

	word_index := bit_index / ACCESS_MASK_WORD_BITS
	bit_index_in_word := bit_index % ACCESS_MASK_WORD_BITS

	mask.words[word_index] = u64(1) << bit_index_in_word

	return mask
}

access_mask_or :: #force_inline proc(dst: ^Access_Mask, src: Access_Mask) {
	for i in 0 ..< ACCESS_MASK_WORD_COUNT {
		dst.words[i] |= src.words[i]
	}
}

access_mask_intersects :: #force_inline proc(a: Access_Mask, b: Access_Mask) -> bool {
	for i in 0 ..< ACCESS_MASK_WORD_COUNT {
		if (a.words[i] & b.words[i]) != 0 do return true
	}
	return false
}

access_mask_has_bit :: #force_inline proc(mask: Access_Mask, bit_index: u32) -> bool {
	if bit_index >= ACCESS_MASK_CAPACITY do return false
	word_index := bit_index / ACCESS_MASK_WORD_BITS
	bit_index_in_word := bit_index % ACCESS_MASK_WORD_BITS

	return (mask.words[word_index] & (u64(1) << bit_index_in_word)) != 0
}