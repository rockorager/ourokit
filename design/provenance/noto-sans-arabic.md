# Noto Sans Arabic test-font provenance

Ourokit's deterministic complex-script shaping test uses Noto Sans Arabic
2.013 as a fallback face because the pinned Inter Latin fixture does not cover
Arabic. Production applications instead request generic `sans-serif` and use
Fontconfig's configured fallback order. This test fixture does not establish
application font policy.

Zig fetches the exact upstream distribution from
`https://github.com/notofonts/arabic/releases/download/NotoSansArabic-v2.013/NotoSansArabic-v2.013.zip`.
Its content hash is recorded in `build.zig.zon`; the test uses
`NotoSansArabic/unhinted/slim-variable-ttf/NotoSansArabic[wght].ttf`.

Noto Sans Arabic is Copyright 2022 The Noto Project Authors and is licensed
under the SIL Open Font License 1.1. The upstream archive includes `OFL.txt`.
The dependency is lazy and is fetched only by steps that compile the test
suite.
