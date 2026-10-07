The `*_paths_test.jsonl` files are generated (design/statecharts.md §14):

    ouroctl test --generate examples/documents --from examples/documents/tests/seed.jsonl

`seed.jsonl` is not a test. It is a hand-written recording with a canceled
and a successful chooser result and Open… and drop results, so generation
reaches the cancel and open paths without real dialogs or files.
