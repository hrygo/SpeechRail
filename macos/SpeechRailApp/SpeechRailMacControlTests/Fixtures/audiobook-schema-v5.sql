-- Frozen historical DDL: v4.0.0 (9572c4e5bb5404ab1da3b69dc9e282cfbd35c6a6).
-- Reproduces the affected user_version=5 database: historical books/chapters
-- without analysis_failure_json/is_skipped, plus the pronunciation table from
-- 21546d72. This fixture must never be regenerated from the live schema.

PRAGMA journal_mode = WAL;
PRAGMA synchronous = NORMAL;
PRAGMA foreign_keys = ON;

CREATE TABLE IF NOT EXISTS books (
    id TEXT PRIMARY KEY NOT NULL,
    source_id TEXT NOT NULL,
    title TEXT NOT NULL,
    author TEXT,
    source_sha256 TEXT NOT NULL,
    canonical_byte_count INTEGER NOT NULL,
    scalar_count INTEGER NOT NULL,
    original_encoding TEXT NOT NULL,
    analysis_state TEXT NOT NULL,
    production_state TEXT NOT NULL,
    listenable_state TEXT NOT NULL,
    confirmed_cast_revision_id TEXT,
    confirmed_audition_digest TEXT,
    current_production_revision_id TEXT,
    created_at REAL NOT NULL,
    updated_at REAL NOT NULL,
    UNIQUE (id, source_id)
);

CREATE TABLE IF NOT EXISTS sources (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    sha256 TEXT NOT NULL,
    canonical_byte_count INTEGER NOT NULL,
    scalar_count INTEGER NOT NULL,
    original_encoding TEXT NOT NULL,
    original_rel_path TEXT NOT NULL,
    canonical_rel_path TEXT NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS casting_revisions (
    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
    id TEXT UNIQUE NOT NULL,
    book_id TEXT NOT NULL,
    restores_revision_id TEXT,
    undone_by TEXT,
    record_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS voice_registration_intents (
    id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    role_id TEXT,
    voice_id TEXT NOT NULL,
    target_metadata_digest TEXT NOT NULL,
    expected_cast_revision_id TEXT NOT NULL,
    expected_voice_set_digest TEXT NOT NULL,
    phase TEXT NOT NULL,
    intent_json TEXT NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS production_checkpoints (
    book_id TEXT PRIMARY KEY NOT NULL,
    checkpoint_json TEXT NOT NULL,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS chapters (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    title TEXT NOT NULL,
    lower_bound INTEGER NOT NULL,
    upper_bound INTEGER NOT NULL,
    excluded_ranges_json TEXT NOT NULL,
    current_chapter_revision_id TEXT,
    previous_chapter_revision_id TEXT,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, source_id) REFERENCES sources(book_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chapters_book_ordinal ON chapters(book_id, ordinal);

CREATE TABLE IF NOT EXISTS text_atoms (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    lower_bound INTEGER NOT NULL,
    upper_bound INTEGER NOT NULL,
    kind TEXT NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_atoms_chapter_ordinal ON text_atoms(book_id, chapter_id, ordinal);

CREATE TABLE IF NOT EXISTS characters (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    display_name TEXT NOT NULL,
    aliases_json TEXT NOT NULL,
    is_narrator INTEGER NOT NULL,
    is_major INTEGER NOT NULL,
    allow_shared_minor_voice INTEGER NOT NULL,
    evidences_json TEXT NOT NULL,
    first_lower_bound INTEGER,
    first_upper_bound INTEGER,
    chapter_ids_json TEXT NOT NULL,
    voice_policy_json TEXT,
    manual_tier TEXT,
    voice_traits_json TEXT,
    required_voice_traits_json TEXT,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS voice_bindings (
    book_id TEXT NOT NULL,
    role_id TEXT NOT NULL,
    voice_id TEXT NOT NULL,
    voice_revision TEXT,
    model_revision TEXT NOT NULL,
    is_synthesis_ready INTEGER NOT NULL,
    allowed_speed REAL NOT NULL,
    caller_seed INTEGER,
    binding_digest TEXT NOT NULL,
    actual_voice_revision TEXT,
    actual_model_revision TEXT,
    PRIMARY KEY (book_id, role_id),
    FOREIGN KEY (book_id, role_id) REFERENCES characters(book_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS analysis_windows (
    id TEXT NOT NULL,
    root_window_id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    primary_atom_ids_json TEXT NOT NULL,
    leading_context_ids_json TEXT NOT NULL,
    trailing_context_ids_json TEXT NOT NULL,
    policy_fingerprint TEXT NOT NULL,
    configuration_digest TEXT NOT NULL,
    generation INTEGER NOT NULL,
    is_completed INTEGER NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS annotations (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    window_id TEXT NOT NULL,
    atom_id TEXT NOT NULL,
    lower_bound INTEGER NOT NULL,
    upper_bound INTEGER NOT NULL,
    assignment_json TEXT NOT NULL,
    evidence TEXT,
    user_confirmed INTEGER NOT NULL,
    annotation_revision INTEGER NOT NULL,
    PRIMARY KEY (book_id, id),
    UNIQUE (book_id, atom_id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_annotations_chapter ON annotations(book_id, chapter_id, lower_bound);

CREATE TABLE IF NOT EXISTS fragments (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    ordinal INTEGER NOT NULL,
    role_id TEXT NOT NULL,
    lower_bound INTEGER NOT NULL,
    upper_bound INTEGER NOT NULL,
    atom_ids_json TEXT NOT NULL,
    local_assignment_digest TEXT NOT NULL,
    voice_binding_digest TEXT NOT NULL,
    policy_digest TEXT NOT NULL,
    dependency_digest TEXT NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_fragments_chapter_ordinal ON fragments(book_id, chapter_id, ordinal);

CREATE TABLE IF NOT EXISTS render_candidates (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    fragment_id TEXT NOT NULL,
    task_id TEXT NOT NULL,
    generation INTEGER NOT NULL,
    relative_asset_path TEXT NOT NULL,
    file_sha256 TEXT NOT NULL,
    pcm_sha256 TEXT NOT NULL,
    frame_count INTEGER NOT NULL,
    sample_rate INTEGER NOT NULL,
    dependency_digest TEXT NOT NULL,
    request_id TEXT,
    receipt_digest TEXT,
    recipe_summary TEXT,
    is_receipt_verified INTEGER NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_candidates_fragment ON render_candidates(book_id, fragment_id, created_at);

CREATE TABLE IF NOT EXISTS chapter_revisions (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    chapter_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    revision_number INTEGER NOT NULL,
    ordered_bindings_json TEXT NOT NULL,
    total_frame_count INTEGER NOT NULL,
    sample_rate INTEGER NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id, chapter_id) REFERENCES chapters(book_id, id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS production_revisions (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    chapter_revisions_json TEXT NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS bookmarks (
    book_id TEXT PRIMARY KEY NOT NULL,
    chapter_id TEXT NOT NULL,
    chapter_revision_id TEXT NOT NULL,
    fragment_id TEXT NOT NULL,
    anchor_lower_bound INTEGER NOT NULL,
    anchor_upper_bound INTEGER NOT NULL,
    fragment_offset_seconds REAL NOT NULL,
    playback_rate REAL NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS export_records (
    id TEXT NOT NULL,
    book_id TEXT NOT NULL,
    production_revision_id TEXT NOT NULL,
    profile_raw_value TEXT NOT NULL,
    exported_chapter_ids_json TEXT NOT NULL,
    omitted_chapters_json TEXT NOT NULL,
    final_file_sha256 TEXT NOT NULL,
    total_frame_count INTEGER NOT NULL,
    duration_seconds REAL NOT NULL,
    created_at REAL NOT NULL,
    PRIMARY KEY (book_id, id),
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS asset_transactions (
    candidate_id TEXT PRIMARY KEY NOT NULL,
    book_id TEXT NOT NULL,
    fragment_id TEXT NOT NULL,
    relative_asset_path TEXT NOT NULL,
    temp_asset_path TEXT NOT NULL,
    file_sha256 TEXT NOT NULL,
    pcm_sha256 TEXT NOT NULL,
    state TEXT NOT NULL,
    candidate_json TEXT NOT NULL,
    updated_at REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS pronunciation_bindings (
    book_id TEXT PRIMARY KEY NOT NULL,
    set_id TEXT NOT NULL,
    revision TEXT NOT NULL,
    entries_json TEXT NOT NULL,
    updated_at REAL NOT NULL,
    FOREIGN KEY (book_id) REFERENCES books(id) ON DELETE CASCADE
);

PRAGMA user_version = 5;
