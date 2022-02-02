```unison
ping _ = 5
pong _ = !ping + 2
```

```ucm
.> add
```

```unison
ping _ = !pong + 1
```

```ucm
.> update
.> view ping pong
```

`ping` and `pong` end up in the same component, because `ping` was updated to become mutually recursive with `pong`.
