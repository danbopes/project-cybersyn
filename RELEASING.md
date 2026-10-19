# Releasing

This fork ships as a zip attached to a GitHub Release on `danbopes/project-cybersyn`. Nothing goes to the Factorio mod portal until the Factorio 2.1 line (see the last section). The mod keeps the name `cybersyn` and `factorio_version` "2.0", so players install it by dropping the zip into their `mods` folder in place of the portal copy.

One script, `tools/package.sh`, builds the zip both on your machine and in CI. If it refuses locally, the release workflow would have refused too.

## 1. Before you bump

- Set the dev interface default to off. In `cybersyn/settings.lua` the startup setting `cybersyn-manager-dev-interface` must have `default_value = false`; with `true` every player gets the test remote interface. `package.sh` refuses to build while it's `true`. The headless lab still needs it on, so give the lab's `mod-settings.dat` the setting instead of flipping the default back.
- Run the host unit tests: `tests/unit/run.sh` must end in `PASS n FAIL 0`.
- Run the in-game suite per `tests/README.md` section 2 (`tests/lab/run.sh <scratch> <rcon port>`), which needs Factorio 2.0 headless and takes about 14 s.

## 2. Bump the version and date the changelog

Edit two files by hand in one commit; that's what most Factorio mods do (raiguard's mods, FactorioAccess, cybersyn-combinator, and upstream all release this way):

1. `cybersyn/info.json`: set `"version"` to the new `a.b.c`.
2. `cybersyn/changelog.txt`: the new block goes on top and its `Version:` line must match. Set `Date:` to the release day.

```
---------------------------------------------------------------------------------------------------
Version: 3.0.1
Date: 2026-11-02
  Bugfixes:
    - One line per entry; a long entry may wrap onto lines indented 6 spaces
```

Factorio throws away the whole in-game changelog if one line breaks its format, so check it before committing:

```sh
python3 -I tools/changelog.py check --version 3.0.1 --top
```

It flags tabs, trailing spaces, separators that aren't 99 dashes, a missing `Version:` line after a separator, bad indentation, duplicate entries, and a top block that isn't the version you named.

If you use the FMTK VS Code extension, its "Increment Version" and "Datestamp" tasks write the same format. Don't use its "Publish" task here: it tags without the `v` prefix and uploads to the portal.

Then build locally once:

```sh
tools/package.sh                 # writes dist/cybersyn_3.0.1.zip and prints the path
unzip -l dist/cybersyn_3.0.1.zip
```

The zip holds one folder, `cybersyn_<version>/`, with every tracked file under `cybersyn/` except `CLAUDE.md`, dotfiles and zips, plus the repo's `LICENSE`. Untracked files never get in. The script refuses on uncommitted changes under `cybersyn/`; `--allow-dirty` skips that for a throwaway local build, and `--out DIR` (or `PACKAGE_OUT_DIR`) writes somewhere other than `dist/`.

`PACKAGE_ALLOW_DEV_INTERFACE=1` skips the dev-interface check. CI's dry run uses it to prove the zip still builds; never attach a zip built with it to a release.

## 3. Tag and push

```sh
git commit -am "Release 3.0.1"
git tag v3.0.1
git push origin HEAD v3.0.1
```

The tag is `v` plus the exact `info.json` version. Anything else won't match the workflow's tag filter, or fails its first step.

## 4. What the workflow does

`.github/workflows/release.yml` runs on any `v*.*.*` tag:

1. fails unless the tag equals `v` + `info.json` version
2. installs `lua5.2` and runs `tests/unit/run.sh`
3. validates `changelog.txt` and requires this version's block on top
4. runs `tools/package.sh` with every guard on, then lists the zip
5. turns this version's changelog block into Markdown release notes (`tools/changelog.py section --markdown`)
6. creates the GitHub Release "Project Cybersyn a.b.c" with `softprops/action-gh-release@v2` and attaches `cybersyn_a.b.c.zip`

`.github/workflows/ci.yml` runs the unit tests and a packaging dry run on every push and pull request, and uploads the zip as a workflow artifact for 14 days.

## 5. When the release run fails

Read the failed step's log on the Actions tab. Then:

- Nothing in the commit needs to change (a flaky runner, a GitHub outage): press "Re-run jobs". The release action updates an existing release and replaces the asset, so a second run is safe.
- The commit needs a fix: fix it on the branch, then move the tag. Delete the half-made release first if one exists.

  ```sh
  gh release delete v3.0.1 --yes        # only if the run got that far
  git tag -f v3.0.1 && git push -f origin v3.0.1
  ```

- To rebuild a release for a tag that already exists without pushing it again, run the Release workflow by hand ("Run workflow", tag `v3.0.1`).

Moving a tag is fine before anyone has downloaded the zip. After that, cut `3.0.2` instead.

## Factorio 2.1 plan

When this fork moves to 2.1 it goes on the mod portal under a new name, because `cybersyn` there belongs to Mami. The new `info.json` gets `"migrates_from": ["cybersyn"]` so existing saves carry over. Upstream's 2.1 migration runner looks up the literal `mod_changes["cybersyn"]`; under a new name that key is absent, so it has to read `mod_changes[script.mod_name]` instead or no migration runs. Portal uploads (`init_publish` for the first release, `init_upload` after that, both with an API key stored as a repo secret) get added to the release workflow at that point and not before.
