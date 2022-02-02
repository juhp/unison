```unison
ping _ = !pong + 1
pong _ = !ping + 2
```

```ucm
.> add
```

```unison
ping _ = !pong + 3
```

```ucm
.> update
.> names ping
.> names pong
.> view ping pong
```

`ping` and `pong` end up in the same component, even though only `ping` was edited.
