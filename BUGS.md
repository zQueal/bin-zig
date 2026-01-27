# Bug Report

## 🚨 CRITICAL ISSUES

### 1. Memory Leak in GitHub Release Parsing
**File**: `src/github.zig`  
**Line**: 58-60  
**Confidence**: 95

**Description**: The `fetchRelease` function uses `std.json.parseFromSlice` to parse JSON but the `parsed` object is never deinitialized. The comment on line 53 says `// defer parsed.deinit(); // Caller needs the strings`, but the strings are copied into the returned struct via `allocator.dupe()`, so the parsed object can and should be deinitialized after copying.

**Code Snippet**:
```zig
const parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
// defer parsed.deinit(); // Caller needs the strings - INCORRECT COMMENT

const root = parsed.value;
// ... copy strings via allocator.dupe() ...
return release; // parsed leaks memory here
```

**Comparison**: In `gitlab.zig`, `codeberg.zig`, and `info.zig`, the `parsed.deinit()` is correctly called after copying the needed data.

**Fix Suggestion**: Add `defer parsed.deinit();` after line 58, or move it to line 91 before the return statement, after all strings have been copied.

---

### 2. Thread Management Bug in Parallel Download
**File**: `src/download.zig`  
**Lines**: 157-204  
**Confidence**: 93

**Description**: In `downloadParallel()`, if `std.Thread.spawn` fails at line 157, the error propagates up. However, threads that were already spawned in previous loop iterations are never joined, leaving them in an undefined state. The defer blocks at lines 127-136 only free memory but don't join threads.

**Code Snippet**:
```zig
for (0..options.threads) |i| {
    // ... context setup ...
    threads[i] = try std.Thread.spawn(.{}, downloadChunk, .{&contexts[i]}); // LINE 157
}

// ... reporter loop ...

for (threads) |t| {  // Never reached if spawn fails
    t.join();
}
```

**Impact**: If thread spawning fails (e.g., resource exhaustion), the program will have:
- Some threads still running and accessing shared resources (file, progress_values)
- No way to wait for them to complete
- Potential data corruption or undefined behavior

**Fix Suggestion**: 
```zig
for (0..options.threads) |i| {
    // ... context setup ...
    threads[i] = std.Thread.spawn(.{}, downloadChunk, .{&contexts[i]}) catch |err| {
        // Join previously spawned threads before returning error
        for (0..i) |j| threads[j].join();
        return err;
    };
}
```

---

## ⚠️ IMPORTANT ISSUES

### 3. Case-Sensitive Binary Name Matching on Windows
**File**: `src/remove.zig`  
**Lines**: 11-23  
**Confidence**: 88

**Description**: The `remove` function compares binary names using `std.mem.eql(u8)`, which is case-sensitive. On Windows, file systems are typically case-insensitive (NTFS), so users could have installed a binary with one case (e.g., "gh") but try to remove it with a different case (e.g., "GH" or "Gh"), which will fail.

**Code Snippet**:
```zig
var input_clean = name;
if (std.mem.endsWith(u8, name, ".exe")) {
    input_clean = name[0 .. name.len - 4];
}

// ... inside iterator ...
if (std.mem.eql(u8, remote_clean, input_clean)) {  // Case-sensitive!
    bin_to_remove = entry.value_ptr.*;
    key_to_remove = entry.key_ptr.*;
    break;
}
```

**Comparison**: The `pin` and `unpin` functions have the same issue.

**Impact**: Users on Windows may be unable to remove/pin/unpin binaries due to case mismatches. The error message "Binary 'X' not found in managed list" would be confusing.

**Fix Suggestion**: On Windows, convert both strings to lowercase (or uppercase) before comparison. Alternatively, use a case-insensitive comparison function.

---

### 4. Duplicate Binary Entries Due to Path-Based Keys
**File**: `src/install.zig`  
**Lines**: 214-222  
**Confidence**: 85

**Description**: The `finalizeInstall` function stores binary entries in the config using the full **file path** as the key (`conf.bins.put(new_bin.path, new_bin)`), not the remote name. This means:
1. Reinstalling the same binary creates a new entry with a different path (e.g., due to version change)
2. Multiple entries for the same logical binary can exist
3. The `remove` function only removes the **first** matching entry by remote name
4. Orphaned entries accumulate over time

**Code Snippet**:
```zig
var new_bin = config.Binary{
    .path = try allocator.dupe(u8, final_bin_path),
    .remote_name = try allocator.dupe(u8, install_name),
    .version = try allocator.dupe(u8, version),
    .url = try allocator.dupe(u8, url),
    .provider = try allocator.dupe(u8, provider_name),
};
try conf.bins.put(new_bin.path, new_bin);  // PATH is the key!
```

**Impact**:
- Users may have multiple versions of the same binary in their config
- The `remove` command only removes one entry (the first found)
- `prune` can clean up orphaned entries, but users might not be aware to run it
- Config file grows unnecessarily large

**Fix Suggestion**: Use `remote_name` (or `remote_name` + some unique identifier) as the key instead of the full path. Or check if an entry with the same `remote_name` already exists and update it instead of creating a new one.

---

### 5. Error Handling Gap in Ensure Command
**File**: `src/ensure.zig`  
**Lines**: 11-16  
**Confidence**: 82

**Description**: The `ensure` function catches `error.FileNotFound` to reinstall missing binaries, but silently ignores other errors (e.g., permission denied, invalid path). This means binaries with filesystem issues won't be detected or reported.

**Code Snippet**:
```zig
const f = std.Io.Dir.openFileAbsolute(io, bin.path, .{}) catch |err| {
    if (err == error.FileNotFound) {
        std.log.info("Binary {s} missing at {s}, reinstalling...", .{ bin.remote_name, bin.path });
        try install.install(allocator, conf, bin.url, env, io, .{ .alias = bin.remote_name });
    }
    continue;  // Silently ignores other errors!
};
```

**Impact**: If a binary has permission issues, corrupted filesystem, or the path is invalid, the user won't be informed. The binary won't work, but `ensure` reports success (or at least doesn't report failure).

**Fix Suggestion**: Log warnings for non-FileNotFound errors:
```zig
const f = std.Io.Dir.openFileAbsolute(io, bin.path, .{}) catch |err| {
    if (err == error.FileNotFound) {
        std.log.info("Binary {s} missing at {s}, reinstalling...", .{ bin.remote_name, bin.path });
        try install.install(allocator, conf, bin.url, env, io, .{ .alias = bin.remote_name });
    } else {
        std.log.warn("Cannot access {s}: {}. Skipping.", .{ bin.path, err });
    }
    continue;
};
```

---

## 📊 Summary

| Severity | Count | Issues |
|----------|-------|--------|
| **Critical (91-100)** | 2 | Memory leak in github.zig, Thread management bug in download.zig |
| **Important (80-90)** | 3 | Case sensitivity on Windows, Duplicate binary entries, Error handling in ensure.zig |
| **Total High-Confidence Issues** | **5** | |

---

## ⏭️ Skipped Issues

Rate limit command issues were excluded from this bug hunt per user request.
