# Publication Record

Status: approved for publication on 2026-09-04 as the public reference core for TATWO OS 2.0.

## Replacement intent

The existing public 1.0 tree is Apache-2.0. Its release tags, notices, contributor attribution, forks, and issue history remain accessible. The 2.0 public core is introduced as a separate clean root and joined to the public history by a normal fast-forwardable merge commit. Private source history is not merged, grafted, or copied into the public repository.

## Pre-publication gates

- [x] Repository owner confirmed that a reference core, not the full private desktop App, is the intended public scope.
- [x] File-by-file review.
- [x] Independent secret scan using a second tool.
- [x] License, notice, and trademark wording review.
- [x] Node 20 test and CLI smoke.
- [x] Threat model and restricted CI permissions review.
- [x] Existing 1.0 history preserved without force push.
- [x] Remote tree and downloadable archive inspected after upload.

`package.json` intentionally keeps `private: true` to block accidental npm publication; the planned release surface is a source repository.
