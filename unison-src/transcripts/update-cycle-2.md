```unison
ping _ = !pong + 1
pong _ = !ping + 2
```

```ucm
.> add
```

```unison
ping _ = 5
```

```ucm
.> update
.> view ping pong
```

`pong` refers to the new `ping`, but they are in different components now.
