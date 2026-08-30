# Inter shaping-fixture provenance

Ourokit's deterministic Latin shaping fixture is Inter 4.1, released by Rasmus
Andersson and contributors. The exact upstream distribution is fetched by Zig from
`https://github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip` with the
content hash recorded in `build.zig.zon`.

Inter is licensed under the SIL Open Font License 1.1. The upstream archive
contains `LICENSE.txt`; applications distributing the font must retain that
license. "Inter" is an upstream reserved font name. Ourokit uses the unmodified
upstream font and does not claim ownership of the typeface.

The shaping tests use `InterVariable.ttf` from that distribution. Inter is not
Ourokit's default UI family: production applications request the generic
`sans-serif` family and respect Fontconfig's configured match. The font remains
a lazy build dependency so non-test library builds do not embed or package it.
