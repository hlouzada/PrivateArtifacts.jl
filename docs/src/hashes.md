# Hash Behavior

`JULIA_PKG_IGNORE_HASHES` behaves as in `Pkg`. When true, a `git-tree-sha1` mismatch is logged
and the unpacked artifact is kept. The `sha256` check of the archive is always enforced.
