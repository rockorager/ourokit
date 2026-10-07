`launcher_paths_test.jsonl` is generated (design/statecharts.md §14):

    ouroctl test --generate examples/launcher --from examples/launcher/tests/seed.jsonl

`seed.jsonl` is not a test. It is a hand-written recording that supplies a
small fake `scan` result and a `launch` result, so generation reaches the
states behind discovery without committing a real desktop's application list.
