#!/usr/bin/env python3
"""Offline real-mise integration tests; native tests use private Git URL rewrites.

Run: sh tests/integration.sh [-v] [FakeTests.test_name | NativeTests.test_name]
MISE_BIN/HERDR_BIN may select installed binaries. Native tests skip if Herdr is
absent; mise is required. No subprocess inherits the invoking environment.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
MISE = os.environ.get("MISE_BIN") or shutil.which("mise")
HERDR = os.environ.get("HERDR_BIN") or shutil.which("herdr")


class Sandbox:
    def __init__(self, native=False):
        base = Path("/tmp/opencode")
        self.temp = tempfile.TemporaryDirectory(prefix="herdr-packages-", dir=base if base.is_dir() else None)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        # Explicit executable allowlist, not the user's PATH or mise shims.
        for name in ("git", "sh", "bash", "env", "cp", "chmod", "mkdir", "rm", "cat", "uname", "tar", "gzip", "touch"):
            executable = shutil.which(name)
            if executable:
                (self.bin / name).symlink_to(Path(executable).resolve())
        (self.bin / "python3").symlink_to(Path(sys.executable).resolve())
        self.fake = self.root / "fake"
        self.fake.mkdir()
        if native:
            (self.bin / "herdr").symlink_to(Path(HERDR).resolve())
        else:
            shutil.copyfile(REPO / "tests/fake-herdr", self.bin / "herdr")
            (self.bin / "herdr").chmod(0o755)
        self.home = self.root / "home"
        self.config = self.root / "config/mise/config.toml"
        self.config.parent.mkdir(parents=True)
        for p in (self.home, self.root / "runtime", self.root / "state/herdr", self.root / "config/herdr"):
            p.mkdir(parents=True, exist_ok=True)
        (self.root / "runtime").chmod(0o700)
        self.env = {
            "PATH": str(self.bin), "HOME": str(self.home), "LANG": "C.UTF-8", "LC_ALL": "C.UTF-8",
            "XDG_CONFIG_HOME": str(self.root / "config"), "XDG_DATA_HOME": str(self.root / "data"),
            "XDG_STATE_HOME": str(self.root / "state"), "XDG_CACHE_HOME": str(self.root / "cache"),
            "XDG_RUNTIME_DIR": str(self.root / "runtime"), "TMPDIR": str(self.root),
            "MISE_DATA_DIR": str(self.root / "mise-data"), "MISE_CACHE_DIR": str(self.root / "cache/mise"),
            "MISE_CONFIG_DIR": str(self.config.parent), "MISE_GLOBAL_CONFIG_FILE": str(self.config),
            "MISE_YES": "1", "MISE_COLOR": "0", "MISE_PARANOID": "0",
            "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "FAKE_HERDR_DIR": str(self.fake),
        }
        self.config.write_text("")

    def run(self, args, ok=True):
        result = subprocess.run([str(a) for a in args], cwd=self.home, env=dict(self.env), text=True, capture_output=True, timeout=90)
        if ok and result.returncode:
            raise AssertionError(f"{args!r}: exit {result.returncode}\n{result.stdout}\n{result.stderr}")
        return result

    def mise(self, *args, ok=True):
        return self.run([MISE, *args], ok=ok)

    def packages(self, action, *args, ok=True):
        return self.mise("bootstrap", "packages", action, *args, ok=ok)

    def configure(self, packages):
        self.config.write_text("[bootstrap.packages]\n" + "".join(f"{json.dumps('herdr-plugins:' + name)} = {json.dumps(ref)}\n" for name, ref in packages.items()))

    def link(self):
        self.mise("plugins", "link", "herdr-plugins", str(REPO))

    def calls(self):
        path = self.fake / "argv.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def installs(self):
        return [args for args in self.calls() if args[:2] == ["plugin", "install"]]

    def state(self):
        path = self.fake / "plugins.json"
        return json.loads(path.read_text()) if path.exists() else []

    def write_state(self, state):
        (self.fake / "plugins.json").write_text(json.dumps(state))

    def close(self):
        self.temp.cleanup()

    def git(self, repo, *args):
        return self.run(["git", "-C", repo, *args])

    def commit(self, repo):
        self.git(repo, "add", ".")
        self.git(repo, "-c", "user.name=Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-m", "fixture")
        return self.git(repo, "rev-parse", "HEAD").stdout.strip()

    def snapshot_plugin(self, name, source):
        target = self.root / "plugin-sources" / name
        target.mkdir(parents=True)
        for item in ("metadata.lua", "mise.plugin.toml", "hooks", "lib"):
            origin = source / item
            if origin.is_dir():
                shutil.copytree(origin, target / item)
            elif origin.exists():
                shutil.copyfile(origin, target / item)
        self.git(target, "init", "-b", "main")
        self.commit(target)
        return target


@unittest.skipUnless(MISE, "mise must be installed (or set MISE_BIN)")
class FakeTests(unittest.TestCase):
    def setUp(self):
        self.s = Sandbox()
        self.addCleanup(self.s.close)
        self.s.link()

    def test_real_hooks_apply_idempotent_and_manifest_not_pin(self):
        self.s.configure({"Owner/Repo": "v1"})
        before = self.s.packages("status")
        self.assertIn("missing", before.stdout + before.stderr)
        self.s.packages("apply")
        self.s.packages("apply")
        self.assertEqual(self.s.installs(), [["plugin", "install", "owner/repo", "--ref", "v1", "--yes"]])
        self.s.configure({"Owner/Repo": "9.8.7"})
        self.s.packages("apply")
        self.assertEqual(self.s.installs()[-1][4], "9.8.7")

    def test_full_commit_matches_resolved_commit_not_requested_tag(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        self.s.configure({"owner/repo": "a" * 40})
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 1)

    def test_manifest_only_metadata_does_not_satisfy_pin(self):
        self.s.configure({"owner/repo": "latest"})
        self.s.packages("apply")
        state = self.s.state()
        state[0]["source"].pop("resolved_commit")
        self.s.write_state(state)
        self.s.configure({"owner/repo": state[0]["version"]})
        status = self.s.packages("status")
        self.assertIn("missing", status.stdout + status.stderr)
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 2)

    def test_literal_shell_arguments(self):
        source = "Owner/Repo/Space dir/$(touch injected);'quote'"
        ref = "tag;$(touch injected-ref) 'quoted'"
        self.s.configure({source: ref})
        self.s.packages("apply")
        self.assertEqual(self.s.installs(), [["plugin", "install", source.replace("Owner/Repo", "owner/repo"), "--ref", ref, "--yes"]])
        self.assertFalse((self.s.home / "injected").exists())
        self.assertFalse((self.s.home / "injected-ref").exists())

    def test_conflicting_canonical_aliases_fail_before_install(self):
        self.s.configure({"Owner/Repo": "v1", "owner/repo": "v2"})
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("conflicting refs", result.stderr)
        self.assertEqual(self.s.installs(), [])

    def test_same_ref_aliases_install_once(self):
        self.s.configure({"Owner/Repo": "v1", "owner/repo": "v1"})
        self.s.packages("apply")
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 1)

    def test_symlink_targets_require_real_manifest_file_and_root_directory(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        state = self.s.state()
        original_root = Path(state[0]["plugin_root"])
        original_manifest = Path(state[0]["manifest_path"])
        linked_root = self.s.root / "linked root 'quoted';$(touch injected)"
        linked_manifest = self.s.root / "linked manifest 'quoted';$(touch injected)"
        linked_root.symlink_to(original_root)
        linked_manifest.symlink_to(original_manifest)
        state[0].update(plugin_root=str(linked_root), manifest_path=str(linked_manifest))
        self.s.write_state(state)
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 1)
        self.assertFalse((self.s.home / "injected").exists())
        linked_manifest.unlink()
        linked_manifest.symlink_to(original_root)
        status = self.s.packages("status")
        self.assertIn("missing", status.stdout + status.stderr)
        linked_manifest.unlink()
        linked_manifest.symlink_to(original_manifest)
        linked_root.unlink()
        linked_root.symlink_to(original_manifest)
        status = self.s.packages("status")
        self.assertIn("missing", status.stdout + status.stderr)

    def test_status_and_dry_runs_do_not_mutate(self):
        self.s.configure({"owner/repo": "latest"})
        self.s.packages("apply", "--dry-run")
        self.assertEqual(self.s.installs(), [])
        self.assertEqual(self.s.state(), [])
        self.s.packages("apply")
        state = (self.s.fake / "plugins.json").read_bytes()
        config = self.s.config.read_bytes()
        self.s.packages("status")
        self.s.packages("upgrade", "--dry-run")
        self.s.configure({"owner/repo": "v2"})
        mismatch_config = self.s.config.read_bytes()
        self.s.packages("apply", "--dry-run")
        self.assertEqual(self.s.config.read_bytes(), mismatch_config)
        self.s.configure({"owner/repo": "latest"})
        self.assertEqual(len(self.s.installs()), 1)
        self.assertEqual((self.s.fake / "plugins.json").read_bytes(), state)
        self.assertEqual(self.s.config.read_bytes(), config)

    def test_upgrade_latest_keeps_pins_and_unrelated(self):
        self.s.configure({"owner/latest": "latest", "owner/pinned": "v1", "owner/unrelated": "latest"})
        self.s.packages("apply")
        self.s.configure({"owner/latest": "latest", "owner/pinned": "v1"})
        before = len(self.s.installs())
        self.s.packages("upgrade")
        self.assertEqual(self.s.installs()[before:], [["plugin", "install", "owner/latest", "--yes"]])
        self.assertEqual(len(self.s.state()), 3)

    def test_failure_no_retry_preserves_completed_install(self):
        self.s.configure({"owner/a-first": "latest", "owner/z-failure": "latest"})
        (self.s.fake / "failures.json").write_text(json.dumps(["owner/z-failure"]))
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owner/z-failure", result.stdout + result.stderr)
        self.assertEqual(self.s.installs(), [["plugin", "install", "owner/a-first", "--yes"], ["plugin", "install", "owner/z-failure", "--yes"]])
        self.assertEqual([p["source"]["repo"] for p in self.s.state()], ["a-first"])

    def test_disabled_matching_accepted_updates_refused(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        state = self.s.state()
        state[0]["enabled"] = False
        self.s.write_state(state)
        self.s.packages("apply")
        self.s.configure({"owner/repo": "v2"})
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("disabled", result.stderr)
        self.s.configure({"owner/repo": "latest"})
        result = self.s.packages("upgrade", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.s.installs()), 1)
        self.assertFalse(self.s.state()[0]["enabled"])

    def test_broken_paths_repaired(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        Path(self.s.state()[0]["manifest_path"]).unlink()
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 2)

    def test_duplicate_sources_fail_without_install(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        state = self.s.state()
        state.append(dict(state[0], plugin_id="duplicate"))
        self.s.write_state(state)
        result = self.s.packages("status", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ambiguous", result.stderr)
        self.assertEqual(len(self.s.installs()), 1)

    def test_invalid_envelopes_fail_not_empty(self):
        self.s.configure({"owner/repo": "latest"})
        invalid = ["not JSON", "null", "[]", "{}", '{"error":{"message":"native error"}}', '{"error":null,"result":{"type":"plugin_list","plugins":[]}}', '{"result":[]}', '{"result":{"type":"plugin_list","plugins":{}}}', '{"result":{"type":"plugin_list","plugins":null}}', '{"result":{"type":"other","plugins":[]}}']
        for output in invalid:
            with self.subTest(output=output):
                (self.s.fake / "list-output").write_text(output)
                result = self.s.packages("apply", ok=False)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.s.installs(), [])

    def test_invalid_native_required_fields_fail_before_install(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        original = self.s.state()[0]
        for field, value in (("plugin_id", None), ("plugin_root", {}), ("manifest_path", []), ("version", ""), ("enabled", "true"), ("source", None), ("source", [])):
            with self.subTest(field=field, value=value):
                self.s.write_state([dict(original, **{field: value})])
                self.assertNotEqual(self.s.packages("apply", ok=False).returncode, 0)
        self.assertEqual(len(self.s.installs()), 1)

    def test_optional_native_fields_null_and_wrong_types_fail(self):
        self.s.configure({"owner/repo": "v1"})
        self.s.packages("apply")
        original = self.s.state()
        for field in ("subdir", "requested_ref", "resolved_commit"):
            for value in (None, {}, [], 12):
                with self.subTest(field=field, value=value):
                    state = json.loads(json.dumps(original))
                    state[0]["source"][field] = value
                    self.s.write_state(state)
                    self.assertNotEqual(self.s.packages("status", ok=False).returncode, 0)
        for warnings in (None, {}, [None]):
            with self.subTest(warnings=warnings):
                self.s.write_state([dict(original[0], warnings=warnings)])
                self.assertNotEqual(self.s.packages("status", ok=False).returncode, 0)
        self.assertEqual(len(self.s.installs()), 1)

    def test_native_list_failure_has_no_mutation(self):
        self.s.configure({"owner/repo": "latest"})
        (self.s.fake / "list-error").write_text("fixture registry cannot be read")
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("herdr plugin list", result.stderr)
        self.assertEqual(self.s.installs(), [])

    def test_post_action_wrong_ref_not_reported_satisfied(self):
        self.s.configure({"owner/repo": "v1"})
        (self.s.fake / "installed-ref").write_text("wrong-ref")
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(len(self.s.installs()), 1)
        status = self.s.packages("status")
        self.assertIn("wrong-ref", status.stdout + status.stderr)

    def test_invalid_requests_rejected_before_install(self):
        for name, ref in (("owner/repo/../bad", "latest"), ("owner/repo", "-bad"), ("owner/repo", "line\nbreak")):
            with self.subTest(name=name, ref=ref):
                self.s.configure({name: ref})
                self.assertNotEqual(self.s.packages("apply", ok=False).returncode, 0)
        self.assertEqual(self.s.installs(), [])

    def test_missing_required_executables(self):
        self.s.configure({"owner/repo": "latest"})
        for name in ("git", "herdr"):
            with self.subTest(name=name):
                path = self.s.bin / name
                saved = self.s.bin / (name + ".saved")
                path.rename(saved)
                try:
                    # mise 2026.10.6 deliberately skips unavailable managers,
                    # returning success. The actionable notice is debug-only.
                    result = self.s.packages("apply", "-v")
                    self.assertIn(f"required binary '{name}' not found", result.stderr)
                    self.assertIn("add it to [tools]", result.stderr)
                finally:
                    saved.rename(path)
        self.assertEqual(self.s.installs(), [])

    def test_empty_config_does_not_call_herdr(self):
        self.s.configure({})
        self.s.packages("status")
        self.s.packages("apply")
        self.s.packages("upgrade")
        self.assertEqual(self.s.calls(), [])

    def test_subdir_case_is_significant_local_source_not_adopted(self):
        self.s.configure({"owner/repo/Case": "v1"})
        self.s.packages("apply")
        self.s.configure({"owner/repo/case": "v1"})
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 2)
        self.s.configure({"owner/repo/Case": "v1"})
        state = self.s.state()
        state[0]["source"]["kind"] = "local"
        self.s.write_state(state)
        self.s.packages("apply")
        self.assertEqual(len(self.s.installs()), 3)

    def test_upgrade_subset_and_pinned_mismatch(self):
        self.s.configure({"owner/one": "latest", "owner/two": "latest", "owner/pinned": "v1"})
        self.s.packages("apply")
        before = len(self.s.installs())
        self.s.packages("upgrade", "herdr-plugins:owner/one")
        self.assertEqual(self.s.installs()[before:], [["plugin", "install", "owner/one", "--yes"]])
        self.s.configure({"owner/pinned": "v2"})
        self.s.packages("upgrade")
        self.assertEqual(self.s.installs()[-1], ["plugin", "install", "owner/pinned", "--ref", "v2", "--yes"])


@unittest.skipUnless(MISE, "mise must be installed")
class BootstrapTests(unittest.TestCase):
    def test_fresh_global_plugins_tools_packages_ordering_offline(self):
        s = Sandbox()
        self.addCleanup(s.close)
        (s.bin / "herdr").unlink()
        package_plugin = s.snapshot_plugin("herdr-plugins", REPO)
        tool_plugin = s.snapshot_plugin("herdr-fixture", REPO / "tests/fixtures/herdr-tool")
        s.env["FAKE_HERDR_EXECUTABLE"] = str(REPO / "tests/fake-herdr")
        s.config.write_text(f'''[bootstrap.plugins]
herdr-plugins = {json.dumps(package_plugin.as_uri())}
herdr-fixture = {json.dumps(tool_plugin.as_uri())}
[tools]
herdr-fixture = "1.0.0"
[bootstrap.packages]
"herdr-plugins:owner/repo" = "v1"
''')
        s.mise("bootstrap", "--only", "plugins,packages,tools")
        self.assertTrue((s.root / "mise-data/plugins/herdr-plugins/hooks/package_install.lua").exists())
        self.assertTrue(list((s.root / "mise-data/installs").rglob("bin/herdr")))
        self.assertEqual(s.installs(), [["plugin", "install", "owner/repo", "--ref", "v1", "--yes"]])
        s.mise("bootstrap", "--only", "plugins,packages,tools")
        self.assertEqual(len(s.installs()), 1)


@unittest.skipUnless(MISE and HERDR, "native tests need mise and Herdr (or MISE_BIN/HERDR_BIN)")
class NativeTests(unittest.TestCase):
    def setUp(self):
        self.s = Sandbox(native=True)
        self.addCleanup(self.s.close)
        self.s.link()
        (self.s.root / "gitconfig").write_text(f'[url "file://{self.s.root}/repos/"]\n insteadOf = https://github.com/\n[protocol "file"]\n allow = always\n')
        self.config_sentinel = self.s.root / "config/herdr/config.toml"
        self.state_sentinel = self.s.root / "state/herdr/fixture-sentinel"
        self.config_sentinel.write_text("# isolated config sentinel\n")
        self.state_sentinel.write_text("private state sentinel\n")

    def fixture(self, repo="demo", plugin_id="fixture-native", subdir=None, build=None):
        root = self.s.root / "repos/testowner" / (repo + ".git")
        root.mkdir(parents=True)
        plugin = root / subdir if subdir else root
        plugin.mkdir(parents=True, exist_ok=True)
        command = build or ["sh", "-c", 'echo built >> "$XDG_STATE_HOME/herdr/build-log"; echo built > build-output']
        (plugin / "herdr-plugin.toml").write_text(f'''id = {json.dumps(plugin_id)}
name = "Offline Fixture"
version = "9.8.7"
min_herdr_version = "0.8.0"
platforms = ["linux", "macos"]
[[build]]
command = {json.dumps(command)}
''')
        self.s.git(root, "init", "-b", "main")
        sha = self.s.commit(root)
        self.s.git(root, "tag", "v1")
        return root, sha

    def plugins(self):
        return json.loads(self.s.run(["herdr", "plugin", "list", "--json"]).stdout)["result"]["plugins"]

    def build_count(self):
        path = self.s.root / "state/herdr/build-log"
        return len(path.read_text().splitlines()) if path.exists() else 0

    def sentinels_unchanged(self):
        self.assertEqual(self.config_sentinel.read_text(), "# isolated config sentinel\n")
        self.assertEqual(self.state_sentinel.read_text(), "private state sentinel\n")

    def test_native_schema_idempotence_pin_drift_and_commit(self):
        root, sha = self.fixture()
        self.s.configure({"testowner/demo": "v1"})
        self.s.packages("apply")
        plugin = self.plugins()[0]
        self.assertEqual(plugin["source"]["requested_ref"], "v1")
        self.assertEqual(plugin["source"]["resolved_commit"], sha)
        self.assertEqual(plugin["version"], "9.8.7")
        self.assertEqual(plugin["plugin_id"], "fixture-native")
        self.assertTrue(Path(plugin["plugin_root"]).is_dir())
        self.assertTrue(Path(plugin["manifest_path"]).is_file())
        self.s.packages("apply")
        self.s.configure({"testowner/demo": sha})
        self.s.packages("apply")
        self.assertEqual(self.build_count(), 1)
        (root / "new-version").write_text("new commit\n")
        changed_sha = self.s.commit(root)
        self.s.git(root, "tag", "v2")
        self.s.configure({"testowner/demo": "v2"})
        self.s.packages("apply")
        self.assertEqual(self.plugins()[0]["source"]["resolved_commit"], changed_sha)
        self.assertEqual(self.build_count(), 2)
        self.sentinels_unchanged()

    def test_native_status_dry_runs_preserve_registry_config_state(self):
        self.fixture()
        self.s.configure({"testowner/demo": "latest"})
        self.s.packages("apply", "--dry-run")
        self.assertEqual(self.plugins(), [])
        self.assertEqual(self.build_count(), 0)
        self.s.packages("apply")
        registry = self.s.root / "config/herdr/plugins.json"
        before = registry.read_bytes()
        self.s.packages("status")
        self.s.packages("apply", "--dry-run")
        self.s.packages("upgrade", "--dry-run")
        self.assertEqual(registry.read_bytes(), before)
        self.assertEqual(self.build_count(), 1)
        self.sentinels_unchanged()

    def test_native_latest_upgrade_only_requested_source(self):
        root, sha = self.fixture()
        self.fixture("pinned", "fixture-pinned")
        self.fixture("unrelated", "fixture-unrelated")
        self.s.configure({"testowner/demo": "latest", "testowner/pinned": "v1", "testowner/unrelated": "latest"})
        self.s.packages("apply")
        (root / "head-change").write_text("new default HEAD\n")
        changed_sha = self.s.commit(root)
        self.s.configure({"testowner/demo": "latest", "testowner/pinned": "v1"})
        self.s.packages("apply")
        self.assertEqual(self.build_count(), 3)
        self.s.packages("upgrade", "herdr-plugins:testowner/demo")
        self.assertEqual(self.build_count(), 4)
        plugins = {p["source"]["repo"]: p for p in self.plugins()}
        self.assertEqual(plugins["demo"]["source"]["resolved_commit"], changed_sha)
        self.assertNotEqual(sha, changed_sha)
        self.assertEqual(plugins["pinned"]["source"]["requested_ref"], "v1")
        self.assertIn("unrelated", plugins)
        self.sentinels_unchanged()

    def test_native_subdir_with_spaces(self):
        self.fixture(subdir="Plugins/Space Dir")
        self.s.configure({"testowner/demo/Plugins/Space Dir": "v1"})
        self.s.packages("apply")
        self.s.packages("apply")
        self.assertEqual(self.plugins()[0]["source"]["subdir"], "Plugins/Space Dir")
        self.assertEqual(self.build_count(), 1)

    def test_native_literal_git_ref_metacharacters(self):
        root, sha = self.fixture()
        ref = "v1;echo${IFS}injected"
        self.s.git(root, "tag", ref)
        self.s.configure({"testowner/demo": ref})
        self.s.packages("apply")
        plugin = self.plugins()[0]
        self.assertEqual(plugin["source"]["requested_ref"], ref)
        self.assertEqual(plugin["source"]["resolved_commit"], sha)
        self.assertEqual(self.build_count(), 1)

    def test_native_install_full_commit_pin(self):
        _, sha = self.fixture()
        self.s.configure({"testowner/demo": sha})
        self.s.packages("apply")
        self.s.packages("apply")
        self.s.packages("upgrade")
        self.assertEqual(self.plugins()[0]["source"]["requested_ref"], sha)
        self.assertEqual(self.plugins()[0]["source"]["resolved_commit"], sha)
        self.assertEqual(self.build_count(), 1)

    def test_native_moved_tag_remains_matching_opaque_pin(self):
        root, sha = self.fixture()
        self.s.configure({"testowner/demo": "v1"})
        self.s.packages("apply")
        (root / "tag-drift").write_text("moved tag\n")
        changed_sha = self.s.commit(root)
        self.s.git(root, "tag", "-f", "v1")
        self.s.packages("apply")
        self.s.packages("upgrade")
        self.assertNotEqual(sha, changed_sha)
        self.assertEqual(self.plugins()[0]["source"]["resolved_commit"], sha)
        self.assertEqual(self.build_count(), 1)

    def test_native_missing_manifest_is_missing_then_repaired(self):
        self.fixture()
        self.s.configure({"testowner/demo": "v1"})
        self.s.packages("apply")
        Path(self.plugins()[0]["manifest_path"]).unlink()
        status = self.s.packages("status")
        self.assertIn("missing", status.stdout + status.stderr)
        self.s.packages("apply")
        self.assertTrue(Path(self.plugins()[0]["manifest_path"]).exists())
        self.assertEqual(self.build_count(), 2)
        self.sentinels_unchanged()

    def test_native_build_failure_no_retry_partial_success(self):
        self.fixture("a-first", "fixture-first")
        self.fixture("z-failure", "fixture-failure", build=["sh", "-c", 'echo attempt >> "$XDG_STATE_HOME/herdr/failure-attempts"; echo fixture-build-failure >&2; exit 23'])
        self.s.configure({"testowner/a-first": "latest", "testowner/z-failure": "latest"})
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("testowner/z-failure", result.stderr)
        self.assertIn("fixture-build-failure", result.stderr)
        self.assertEqual((self.s.root / "state/herdr/failure-attempts").read_text(), "attempt\n")
        self.assertEqual([p["plugin_id"] for p in self.plugins()], ["fixture-first"])
        self.sentinels_unchanged()

    def test_native_missing_build_tool(self):
        self.fixture(build=["missing-fixture-build-tool-unique"])
        self.s.configure({"testowner/demo": "v1"})
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("testowner/demo", result.stderr)
        self.assertIn("missing-fixture-build-tool-unique", result.stderr)
        self.assertEqual(self.plugins(), [])
        self.sentinels_unchanged()

    def test_native_local_link_id_conflict_preserves_link(self):
        root, _ = self.fixture()
        self.s.run(["herdr", "plugin", "link", root])
        before = self.plugins()
        self.assertEqual(before[0]["source"]["kind"], "local")
        self.s.configure({"testowner/demo": "v1"})
        result = self.s.packages("apply", ok=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("testowner/demo", result.stderr)
        self.assertEqual(self.plugins(), before)
        self.sentinels_unchanged()


if __name__ == "__main__":
    if not MISE:
        sys.exit("mise is required: install it or set MISE_BIN")
    if os.environ.get("MISE_REQUIRE_NATIVE_TESTS") == "1" and not HERDR:
        sys.exit("Herdr is required for the full suite: install it or set HERDR_BIN")
    unittest.main(verbosity=2)
