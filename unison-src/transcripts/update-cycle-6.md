```unison
ping _ = !pong + 1
pong _ = !ping + 2

pang _ = !pong + 10
```

```ucm
.> add
```

```unison
ping _ = !pang + 1
```

```ucm
.> update
.> view ping pong pang
```

Here `ping`, `pong`, and `pang` all end up in the same component, even though originally `pang` was a dependent of
the `ping`/`pong` component, and only `ping` was updated.
