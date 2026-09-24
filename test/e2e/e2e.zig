pub const Params = struct {
    // Seed Info
    seed_string: [:0]const u8,
    seed: u64,

    // Tardy Initalization
    initial_tasks_size: usize,
    aio_reap_size_max: usize,
};
