package rt

import "sync"

// OnceValue memoises a zero-arg thunk: the first call runs f and caches its
// result; later calls return the cache. Used to give a top-level effectful value
// binding (`dbConn = Task.run (Db.connect ())`, `initSchema = … Db.execRaw …`)
// run-once CAF semantics, so its effect (e.g. CREATE TABLE) doesn't re-run on
// every reference. Thin wrapper over the stdlib (Go 1.21+).
func OnceValue[T any](f func() T) func() T { return sync.OnceValue(f) }
