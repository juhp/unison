```unison
ping _ = !pong + 1
pong _ = !ping + 2
```

```ucm
.> add
```

```unison
ping = "hello"
```

```ucm
.> update
.> view ping pong
```

`pong` ends up referring to a nameless hash, because substituting in the new `ping` didn't typecheck.

```ucm
.> todo
```

2022/02/01: Unfortunately `todo` doesn't show `pong` yet.
