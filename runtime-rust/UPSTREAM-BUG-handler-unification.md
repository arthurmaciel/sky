# Upstream bug report (anzellai/sky) — `Handler` does not unify with `Request -> Task Error Response`; `Sky.Http.Middleware` cannot compose into `Server.get`

**Affects:** both backends (Go and Rust). Found on v0.16.1.

**Severity:** a shipped stdlib module (`Sky.Http.Middleware`) is unusable in its
documented form. Latent because no example/test exercises middleware.

## Summary

`Sky.Http.Middleware`'s `with*` helpers are typed (in the type-checker's special
kernel-signature table) over an opaque builtin type `Handler`:

```
withCors      : List String -> Handler -> Handler
withLogging   : Handler -> Handler
withBasicAuth : String -> String -> Handler -> Handler
withRateLimit : String -> Int -> Int -> Handler -> Handler
```
(`src/Sky/Type/Constrain/Expression.hs` ~line 3211, `Handler = T.TType "" "Handler" []`.)

`Sky.Http.Server.get` is typed with the **structural** handler type:

```
get : String -> (Request -> Task Error Response) -> Route   -- Sky.Http.Server.sky:80
```

There is **no unification rule** making `Handler ~ (Request -> Task Error
Response)`. So the documented composition fails to type-check:

```elm
Server.get "/" (myHandler |> Sky.Http.Middleware.withLogging)
```
```
-- TYPE ERROR [E2001]
Type mismatch: in param 1:
     expected: (Request) -> Task Error (Response)
     actual:   Handler
```

The module doc itself advertises this exact pattern ("compose by chaining with
`|>`"), so the intended usage is impossible.

## Reproduction (target=go, no Rust involved)

```elm
module Main exposing (main)
import Sky.Core.Prelude exposing (..)
import Sky.Core.Task as Task
import Sky.Core.Error as Error exposing (Error)
import Sky.Http.Server as Server
import Sky.Http.Middleware as Mw

home : Server.Request -> Task Error Server.Response
home req = Task.succeed (Server.text "ok")

main = Server.listen 8000 [ Server.get "/" (home |> Mw.withLogging) ]
```
`sky build` → the E2001 above (with `target = "go"`).

## Suggested fix

Make `Handler` a transparent alias for the structural handler type, so it unifies
with `Server.get`'s param and middleware composes. Either:

- treat `Handler` as `Request -> Task Error Response` in the type-checker
  (unify rule / alias expansion in `Constrain` / the unifier), or
- type `Server.get`/`post`/… to accept `Handler` (the opaque type) and add a
  coercion from a bare `(Request -> Task Error Response)` lambda to `Handler`.

The first is least invasive. Add an example/regression that actually composes a
middleware into a route so this can't regress.

## Rust-backend status (this fork)

The Rust middleware **runtime** is implemented and correct
(`runtime-rust/src/sky_runtime/server.rs`: `middleware_with_{cors,logging,
basic_auth,rate_limit}` + `rate_limit_allow`); it's ready the moment the
type-checker accepts the composition. Not blocking on anything Rust-specific.
