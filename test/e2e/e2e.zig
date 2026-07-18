pub const Params = struct {
    // Seed Info
    seed_string: [:0]const u8,
    seed: u64,

    // Tardy Initalization
    size_tasks_initial: usize,
    size_aio_reap_max: usize,
};
