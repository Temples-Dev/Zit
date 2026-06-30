# Zit ⚡

> A ground-up reimplementation of Git, written in [Zig](https://ziglang.org/).

Zit is an educational and systems-programming project that rebuilds the Git version-control system from first principles using Zig. The goal is not to wrap `libgit2` or shell out to the `git` binary — every byte of the protocol, every on-disk format, and every user-facing command is implemented directly in Zig, giving you a precise, auditable understanding of how Git works underneath.

```
         ┌────────────────────────────────────────────────┐
         │                  Working Directory              │
         │            (your actual project files)          │
         └────────────────┬──────────────┬────────────────┘
                          │  zit add     │ zit checkout
                          ▼              ▼
         ┌────────────────────────────────────────────────┐
         │              Index / Staging Area               │
         │           (.git/index  – binary format)         │
         └────────────────┬───────────────────────────────┘
                          │  zit commit
                          ▼
         ┌────────────────────────────────────────────────┐
         │                 Object Store                    │
         │  blob · tree · commit · tag  (.git/objects/)   │
         └──────────┬─────────────────────────────────────┘
                    │                   ▲
          loose     │   pack / idx      │  fetch / push
          objects   ▼   files           │
         ┌──────────────────────────────┴──────────────────┐
         │           Pack-File System  (.git/objects/pack/) │
         └──────────────────────────────────────────────────┘
                          │
                          │  zit branch / zit tag
                          ▼
         ┌────────────────────────────────────────────────┐
         │               Reference Store                   │
         │   (.git/refs/  ·  .git/packed-refs  · HEAD)    │
         └────────────────────────────────────────────────┘
```

---

## Table of Contents

1. [Why Zit?](#why-zit)
2. [Prerequisites](#prerequisites)
3. [Building](#building)
4. [Project Layout](#project-layout)
5. [Architecture: The Six Subsystems](#architecture-the-six-subsystems)
   - [1. The Object Store](#1-the-object-store)
   - [2. The Index / Staging Area](#2-the-index--staging-area)
   - [3. The Reference Store](#3-the-reference-store)
   - [4. The Working Directory](#4-the-working-directory)
   - [5. Core Commands](#5-core-commands)
   - [6. The Pack-File System](#6-the-pack-file-system)
6. [Roadmap](#roadmap)
7. [Contributing](#contributing)
8. [License](#license)

---

## Why Zit?

| Motivation | Detail |
|---|---|
| **Learn Git internals** | Every format documented in `git help gitformat-*` is implemented by hand. |
| **Systems programming in Zig** | Zig's comptime, error unions, and manual memory model are ideal for low-level binary parsing. |
| **No hidden allocations** | Every allocation site is explicit and tracked; Zit pairs well with `std.heap.ArenaAllocator` for per-command lifetimes. |
| **No libc dependency (goal)** | The aim is to build with `-fno-libc` on Linux using `std.os` and `std.fs` directly. |
| **Interoperability** | Zit reads and writes repositories that real `git` can consume. |

---

## Prerequisites

| Tool | Version |
|---|---|
| [Zig](https://ziglang.org/download/) | **≥ 0.16.0** (see `build.zig.zon`) |
| Linux / macOS | Primary targets; Windows support is planned. |
| zlib | System zlib or Zig's `std.compress.zlib` (bundled) |

---

## Building

```bash
# Clone the repo
git clone https://github.com/yourorg/Zit.git
cd Zit

# Build the binary (Debug by default)
zig build

# Run directly
zig build run -- init ./my-repo

# Run all tests
zig build test

# Release build
zig build -Doptimize=ReleaseSafe
```

The compiled binary lands in `zig-out/bin/Zit`.

---

## Project Layout

```
Zit/
├── build.zig            # Build graph – executable + library + tests
├── build.zig.zon        # Package manifest (name, version, dependencies)
└── src/
    ├── root.zig         # Public library API (re-exports subsystem roots)
    ├── main.zig         # CLI entry-point – parses argv, dispatches commands
    │
    ├── object/          # [planned] Object store subsystem
    │   ├── store.zig
    │   ├── blob.zig
    │   ├── tree.zig
    │   ├── commit.zig
    │   └── tag.zig
    │
    ├── index/           # [planned] Index / staging area subsystem
    │   ├── index.zig
    │   └── entry.zig
    │
    ├── refs/            # [planned] Reference store subsystem
    │   ├── store.zig
    │   ├── symref.zig
    │   └── packed.zig
    │
    ├── worktree/        # [planned] Working directory subsystem
    │   ├── diff.zig
    │   └── checkout.zig
    │
    ├── pack/            # [planned] Pack-file subsystem
    │   ├── reader.zig
    │   ├── writer.zig
    │   ├── index.zig
    │   └── delta.zig
    │
    └── cmd/             # [planned] Core user-facing commands
        ├── init.zig
        ├── add.zig
        ├── commit.zig
        ├── status.zig
        ├── log.zig
        ├── diff.zig
        ├── branch.zig
        ├── checkout.zig
        ├── merge.zig
        ├── fetch.zig
        └── push.zig
```

---

## Architecture: The Six Subsystems

### 1. The Object Store

**Location on disk:** `.git/objects/`

The object store is the heart of Git. Every version of every file, every directory snapshot, every commit, and every tag is a **content-addressed object** — its name is the SHA-1 (or SHA-256 in modern Git) hash of its contents.

#### Object Types

| Type | Zig struct (planned) | Description |
|---|---|---|
| `blob` | `object.Blob` | Raw file contents. No metadata. |
| `tree` | `object.Tree` | A directory listing: mode + name + SHA for each entry. |
| `commit` | `object.Commit` | Snapshot pointer: tree SHA, parent SHAs, author, committer, message. |
| `tag` | `object.Tag` | Annotated tag: points to any object, carries its own author and message. |

#### On-Disk Format (Loose Objects)

Each loose object is stored at `.git/objects/<first-2-hex>/<remaining-38-hex>` and is a **zlib-compressed** byte stream with this header:

```
"<type> <size>\0<raw-content-bytes>"
```

For example, a blob containing `hello\n` (6 bytes) is stored as:

```
zlib( "blob 6\0hello\n" )
```

#### Zit Implementation Notes

- Hashing uses `std.crypto.hash.Sha1` from the standard library.
- Compression uses `std.compress.zlib`.
- Object reads are validated by re-hashing content and comparing against the filename — any corruption is caught immediately.
- The store exposes a generic `writeObject(type, content) !Oid` and `readObject(oid) !Object` interface so higher layers never touch the filesystem directly.

---

### 2. The Index / Staging Area

**Location on disk:** `.git/index`

The index is a **binary file** that acts as a virtual tree standing between the working directory and the object store. It records the exact set of files that will be captured in the *next commit*. Understanding the index is the key to understanding `git add`, `git reset`, and three-way merges.

#### Index Entry Fields

Each entry in the index records:

| Field | Size | Description |
|---|---|---|
| `ctime` | 8 bytes | Last metadata-change time (sec + nanosec) |
| `mtime` | 8 bytes | Last data-modification time (sec + nanosec) |
| `dev` | 4 bytes | Device number of the file |
| `ino` | 4 bytes | Inode number |
| `mode` | 4 bytes | File mode (regular, symlink, gitlink) |
| `uid` / `gid` | 4 bytes each | Owner identity |
| `size` | 4 bytes | File size in bytes |
| `oid` | 20 bytes | SHA-1 of the blob object |
| `flags` | 2 bytes | Assume-unchanged, extended, stage, name length |
| `name` | variable | NUL-terminated relative path |

The index header contains a 4-byte magic (`DIRC`), a 4-byte version, and a 4-byte entry count. The file is terminated with a SHA-1 checksum of the entire contents.

#### Zit Implementation Notes

- The index is parsed with `std.io.fixedBufferStream` and a hand-written binary reader — no external parser combinator library needed.
- Entries are kept in a sorted `std.ArrayList(IndexEntry)` for O(log n) lookup by path.
- **Stage numbers** (0–3) in the flags field support conflict markers during merges: stage 0 = normal, stage 1 = common ancestor, stage 2 = ours, stage 3 = theirs.
- `stat` data (ctime, mtime, dev, ino, size) is used as a fast-path to skip re-hashing unchanged files — a critical performance optimisation.

---

### 3. The Reference Store

**Location on disk:** `.git/refs/`, `.git/HEAD`, `.git/packed-refs`

References are **human-readable names** that point to object IDs. Branches, tags, and remote-tracking refs are all references.

#### Reference Hierarchy

```
.git/
├── HEAD                      ← symbolic ref ("ref: refs/heads/main")
│                               or detached (a raw SHA-1)
├── ORIG_HEAD                 ← saved before a merge or reset
├── MERGE_HEAD                ← the tip being merged in
├── refs/
│   ├── heads/                ← local branches
│   │   ├── main
│   │   └── feature/my-work
│   ├── tags/                 ← lightweight and annotated tags
│   │   └── v1.0.0
│   └── remotes/              ← remote-tracking refs
│       └── origin/
│           └── main
└── packed-refs               ← compacted form of many refs (one per line)
```

#### Symbolic Refs

`HEAD` is usually a **symbolic ref** — a file whose contents are literally:

```
ref: refs/heads/main\n
```

Following a symbolic ref is a multi-step resolve: read the symref → resolve the named ref → read the SHA-1 from disk.

#### `packed-refs`

When there are many refs, Git packs them into a single file to reduce `readdir` syscalls:

```
# pack-refs with: peeled fully-peeled sorted
abc123...  refs/tags/v1.0.0
^def456...  ← peeled tag (points to the tagged commit directly)
```

#### Zit Implementation Notes

- Loose ref reads use `std.fs.File.readToEndAlloc` with a fixed maximum of 41 bytes (40 hex + newline).
- `packed-refs` is parsed line-by-line; peel lines (`^<sha>`) are attached to the preceding tag entry.
- Ref updates are **atomic**: write to a `.lock` file, then `std.fs.rename` into place — the same strategy used by real Git to prevent partial writes.
- A `RefTransaction` struct batches multiple ref updates and commits or rolls them back atomically.

---

### 4. The Working Directory

**Location on disk:** the repository root (everything outside `.git/`)

The working directory is the **checked-out view** of a commit — the files you actually edit. Zit must reconcile three trees at once: the current commit (HEAD), the index, and the working directory.

#### Key Operations

| Operation | What Zit Computes |
|---|---|
| `status` | Diffs index↔HEAD (staged changes) and worktree↔index (unstaged changes). |
| `add` | Stats file, hashes content → writes blob to object store → updates index entry. |
| `checkout` | Reads tree from object store → updates index → writes files to disk. |
| `clean` | Identifies untracked files not covered by `.gitignore` patterns. |

#### `.gitignore` Parsing

`.gitignore` patterns are matched against working-directory paths. Rules:

- A leading `/` anchors the pattern to the root.
- A trailing `/` matches directories only.
- `**` matches across directory separators.
- A leading `!` negates the pattern.

Zit maintains a per-directory `IgnoreStack` that layers `.gitignore` files from the root down, evaluated in order from most-specific to least-specific.

#### Zit Implementation Notes

- Directory traversal uses `std.fs.Dir.iterate()` which yields `std.fs.Dir.Entry` values without extra syscalls.
- File hashing for `add` uses a streaming SHA-1 over `std.io.Reader` to avoid loading large files into memory.
- Checkout writes files using `std.fs.Dir.createFile` with `O_EXCL` when safe, falling back to atomic replace via a temp file + rename for overwrites.
- Symlink handling: `stat` vs `lstat` is used carefully; symlink targets themselves are the blob content.

---

### 5. Core Commands

**Location:** `src/cmd/`

Core commands are the porcelain — the user-facing verbs of the Zit CLI. Each command is a thin orchestration layer that wires together the four subsystems above. They follow a strict pattern:

```zig
pub fn run(ctx: *Context, args: []const []const u8) !void {
    // 1. Parse flags from `args`
    // 2. Open repository (locate .git/, load config)
    // 3. Call into subsystem APIs
    // 4. Write output via ctx.io.stdout
    // 5. All errors propagate as Zig error unions
}
```

#### Planned Commands

| Command | Status | Notes |
|---|---|---|
| `init` | 🔲 planned | Creates `.git/` skeleton, writes default config and HEAD. |
| `add` | 🔲 planned | Updates index for given paths; handles `-A`, `-p` (interactive patch). |
| `commit` | 🔲 planned | Writes tree → commit object; advances HEAD/branch ref. |
| `status` | 🔲 planned | Compares HEAD↔index↔worktree; respects `.gitignore`. |
| `log` | 🔲 planned | Walks commit graph; supports `--oneline`, `--graph`, `-n`. |
| `diff` | 🔲 planned | Unified diff between any two tree-ish values or the worktree. |
| `branch` | 🔲 planned | Create, list, delete, rename branches. |
| `checkout` / `switch` | 🔲 planned | Updates HEAD, index, and worktree; three-way merge for safety. |
| `merge` | 🔲 planned | Fast-forward, recursive three-way merge, conflict markers. |
| `fetch` | 🔲 planned | Smart HTTP / SSH transport; negotiation, pack download. |
| `push` | 🔲 planned | Ref advertisement, pack upload, ref update. |
| `clone` | 🔲 planned | `init` + `fetch` + `checkout`. |
| `tag` | 🔲 planned | Lightweight and annotated tag creation. |
| `reset` | 🔲 planned | `--soft`, `--mixed`, `--hard` modes. |
| `stash` | 🔲 planned | Save/restore worktree+index state via stash commits. |

#### Error Handling Philosophy

Every command returns `!void`. Errors are Zig error unions — there are **no unchecked exceptions**. The top-level `main` catches all errors and prints a human-readable message with an appropriate exit code, matching Git's convention of exit code 128 for usage errors and 1 for operational failures.

---

### 6. The Pack-File System

**Location on disk:** `.git/objects/pack/`

A Git repository with millions of commits would be unusable if every object was a separate file. The **pack-file** system solves this by bundling thousands of objects into a single binary file (`.pack`) accompanied by an index (`.idx`) that enables O(log n) lookup by SHA-1.

#### Pack File Structure (`.pack`)

```
┌─────────────────┬───────────────────┬──────────────────────────────┐
│  Header         │  Object entries   │  Trailer (SHA-1 checksum)    │
│  "PACK"         │  (variable count) │  of entire file              │
│  version = 2    │                   │                              │
│  num_objects    │                   │                              │
└─────────────────┴───────────────────┴──────────────────────────────┘
```

Each object entry starts with a **variable-length integer** (MSB encoding) that encodes both the object type and the uncompressed size, followed by the payload which is either:

- **Non-deltified**: zlib-compressed raw object data.
- **`OBJ_OFS_DELTA`**: zlib-compressed delta against an object at a negative byte offset within the same pack file.
- **`OBJ_REF_DELTA`**: zlib-compressed delta against an object referenced by SHA-1 (may be in a different pack or loose).

#### Pack Index (`.idx`) — Version 2

The version-2 index has five sections:

| Section | Description |
|---|---|
| Fan-out table | 256 × 4-byte cumulative counts; `fanout[n]` = total objects whose first byte is ≤ `n`. |
| SHA-1 list | All object SHA-1s in ascending order. |
| CRC32 list | Per-object CRC of the compressed pack data (allows corruption detection without decompression). |
| Offset list | 32-bit pack offsets; high bit set means "use large-offset table". |
| Large-offset table | 64-bit offsets for packs > 2 GiB. |

Lookup algorithm: binary-search the SHA-1 list using fan-out bounds → read 32-bit offset → seek in `.pack`.

#### Delta Encoding

Delta compression is the key to Git's storage efficiency. A delta encodes the *difference* between a **base object** and the **target object** using a simple instruction set:

| Instruction | Meaning |
|---|---|
| `COPY offset size` | Copy `size` bytes starting at `offset` from the base. |
| `INSERT len <data>` | Append `len` literal bytes directly. |

Resolving a delta object may require recursively resolving a chain of deltas. Zit tracks the maximum delta depth to avoid stack overflows and resolves chains iteratively using a small stack allocator.

#### Pack-File Writing (Repacking)

`zit repack` / `zit gc` will:

1. Enumerate all loose objects and existing packs.
2. Compute a delta fan-out graph using a sliding window algorithm (default window size: 10, depth: 50).
3. Sort objects by type + size + filename-similarity heuristic to maximise delta hits.
4. Stream the resulting pack to disk, building the index in parallel.
5. Atomically rename into `pack-*.pack` / `pack-*.idx`.

#### Zit Implementation Notes

- Parsing uses a `PackReader` backed by a memory-mapped file (`std.os.mmap`) for zero-copy access on Linux.
- The delta instruction decoder is a tight loop over a `[]const u8` slice — no allocations during decode.
- A `DeltaCache` (LRU, bounded by memory limit) stores recently resolved base objects to short-circuit long delta chains.
- Pack index lookups use `std.sort.binarySearch` over the SHA-1 section.

---

## Roadmap

```
Phase 1 – Plumbing (in progress)
  ✅ Project scaffold (build.zig, build.zig.zon)
  🔲 Object store: read/write loose objects (blob, tree, commit, tag)
  🔲 Index: parse and serialise the binary index format
  🔲 Reference store: read/write loose refs, packed-refs, symbolic refs
  🔲 Working directory: stat caching, .gitignore

Phase 2 – Core Porcelain
  🔲 zit init / zit hash-object / zit cat-file
  🔲 zit add / zit commit / zit status
  🔲 zit log / zit diff / zit show

Phase 3 – Branching & Merging
  🔲 zit branch / zit switch / zit checkout
  🔲 zit merge (fast-forward + recursive three-way)
  🔲 zit rebase (interactive planned)
  🔲 zit stash

Phase 4 – Pack Files & Networking
  🔲 Pack-file reader (loose → pack lookup)
  🔲 Pack-file writer / repacking / GC
  🔲 Smart HTTP transport (fetch/push) – RFC 7857
  🔲 SSH transport
  🔲 zit clone / zit fetch / zit push

Phase 5 – Polish
  🔲 SHA-256 object format (Git 2.29+)
  🔲 Partial clone / sparse checkout
  🔲 Commit-graph acceleration file
  🔲 Windows support
```

---

## Contributing

Contributions are welcome! Before opening a PR:

1. **Read the Git internals docs** — `git help gitformat-pack`, `git help gitformat-index`, and the [Git Book Chapter 10](https://git-scm.com/book/en/v2/Git-Internals-Plumbing-and-Porcelain) are the primary references.
2. **Run tests** — `zig build test`. All tests must pass.
3. **Match the style** — no `std.debug.print` in library code; use the `Io.Writer` abstraction from `std.Io`. All public functions must have `///` doc-comments.
4. **No external dependencies** — Zit uses only the Zig standard library. Additions require explicit discussion.
5. **Interop test** — if you implement a new on-disk format, add a test that writes data with Zit and verifies it with `git` (or vice versa).

---

## License

MIT © 2026 Zit Contributors

> *"It's not magic, it's just hashes."* — every Git talk ever.
