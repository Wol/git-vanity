# git-vanity

Vibe coded git vanity-hash generator! #justClaudethings

Brute-forces a git commit hash that starts with (or otherwise matches) a chosen pattern by appending a `nonce:` line to the commit message. The search runs on the GPU via CUDA.

## How it works

Git commit hashes are SHA1 over a byte-exact object that includes the tree, parents, author, committer, and message. `git_vanity` fixes all of those and iterates over a 16-digit decimal nonce appended to the message until the SHA1 matches the desired pattern. The nonce is always 16 digits so the commit object size stays constant, allowing the SHA1 midstate to be precomputed on the CPU up to the block containing the nonce. Only 1–2 SHA1 compression rounds run on the GPU per candidate. If the nonce would straddle a 64-byte SHA1 block boundary, the message is padded with trailing spaces to realign it.

`git_vanity_hook` is a post-commit hook. After every `git commit` it reads HEAD, runs `git_vanity`, then writes the amended commit object byte-for-exact-byte to the git ODB and updates HEAD — guaranteeing the recorded hash matches the computed hash.

Separating `git_vanity` and `git_vanity_hook` means that there is potential to run the hash finder on a separate remote PC via SSH instead of locally. A JSON API allows for communication between these two parts.

This was tested and coded on Ubuntu 26.04.

## Dependencies

| Package | Ubuntu/Debian |
|---|---|
| OpenSSL | `libssl-dev` |
| nlohmann-json | `nlohmann-json3-dev` |
| libgit2 | `libgit2-dev` |
| CUDA Toolkit 12+ | from NVIDIA |

## Build

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build
```

Targets:

| Binary | Description |
|---|---|
| `git_vanity` | GPU search kernel (requires NVIDIA GPU) |
| `git_vanity_hook` | Post-commit hook |

By default the CUDA target is compiled for SM 8.9 (Ada Lovelace / RTX 40-series). Edit `CMakeLists.txt` to change `CUDA_ARCHITECTURES` for your GPU (75 = Turing, 86 = Ampere, 89 = Ada, 90 = Hopper).

## Install the hook

```sh
# In any repository you want vanity hashes on:
cp build/git_vanity_hook /path/to/repo/.git/hooks/post-commit
chmod +x /path/to/repo/.git/hooks/post-commit

cp .vanityconfig.example /path/to/repo/.vanityconfig
# Edit .vanityconfig to taste (see below)

# git_vanity must be on PATH
sudo cp build/git_vanity /usr/local/bin/
```

Now every `git commit` automatically amends HEAD to match the configured pattern.

## .vanityconfig

The script is configured using a `.vanityconfig` file which specifies what mode to run in.

```json
{
    "mode":        "prefix",
    "prefix":      "cafe",
    "pairs_count": 4,
    "repeat_count": 4,
    "nonce_label": "nonce"
}
```

| Field | Description                                                                                                                                                         |
|---|---------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `mode` | `"prefix"` — hash must start with `prefix`; `"pairs"` — first N bytes each have matching nibbles (e.g. `0xAA`, `0xBB`); `"repeat"` — first N bytes equal bytes N–2N |
| `prefix` | Hex string to match at the start of the hash (mode: prefix)                                                                                                         |
| `pairs_count` | Number of leading bytes to check for paired nibbles (mode: pairs)                                                                                                   |
| `repeat_count` | Number of bytes N such that hash[0..N-1] == hash[N..2N-1] (mode: repeat)                                                                                            |
| `nonce_label` | Label used in the commit message line, default `nonce`                                                                                                              |

## Examples

**Prefix match** — hash starts with `dead`:
```json
{ "mode": "prefix", "prefix": "dead" }
```
```
commit deadbeef3f2a1c...
Author: ...
    My commit message
    nonce: 0000000004a3f1c2
```

**Paired nibbles** — first 4 bytes all look like `0xAA`, `0x11`, etc.:
```json
{ "mode": "pairs", "pairs_count": 4 }
```
```
commit aa11bb22c3d4...
```

**Repeating pattern** — `hash[0..3] == hash[4..7]`:
```json
{ "mode": "repeat", "repeat_count": 4 }
```
```
commit abcd1234abcd1234...
```

**Custom nonce label**:
```json
{ "mode": "prefix", "prefix": "c0de", "nonce_label": "git-vanity-nonce" }
```
```
    My commit message
    git-vanity-nonce: 0000000001b4c2f8
```

## Running manually

`git_vanity` reads JSON from stdin and writes newline-delimited JSON to stdout:

```sh
echo '{
  "mode": "prefix", "prefix": "cafe",
  "tree":      "<tree-sha>",
  "parent":    "<parent-sha>",
  "author":    "Name <email> 1700000000 +0000",
  "committer": "Name <email> 1700000000 +0000",
  "message":   "My commit message"
}' | git_vanity
```

Output lines:
- `{"type":"info", "baseline_hash":"...", "mode":"..."}` — hash of commit before nonce
- `{"type":"progress", "hashes_tried":..., "hashes_per_sec":...}` — periodic progress
- `{"type":"result", "hash":"...", "nonce":"...", "body":"...", "time_s":..., "hashes_per_sec":...}` — match found; `body` is the raw commit object body ready to write to the ODB
