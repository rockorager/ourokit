The `*_paths_test.jsonl` files are generated (design/statecharts.md §14):

    ouroctl test --generate examples/contacts --from examples/contacts/tests/seed.jsonl

`seed.jsonl` is not a test. It is a hand-written recording with a two-person
`load` result and a failed `save`, so generation reaches `ready` and the
retry states without committing the 500-row sample.
