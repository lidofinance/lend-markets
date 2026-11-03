import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("external_tests", Path(__file__).resolve().parents[1] / "run_external_tests.py")
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)


class ExternalLifecycleTests(unittest.TestCase):
    def exercise(self, states):
        states = dict(states)
        calls = []

        def deploy(market):
            calls.append(("deploy", market))
            states[market] = "inert"

        def activate():
            calls.append(("activate", tuple(m for m, state in states.items() if state == "inert")))
            states.update({m: "active" for m, state in states.items() if state == "inert"})

        before = module.prepare_markets(list(states), lambda m: states[m] != "missing", deploy,
                                        lambda m: states[m] == "active", activate)
        return before, calls, states

    def test_protocol_only_deploys_and_activates(self):
        before, calls, after = self.exercise({"first": "missing"})
        self.assertEqual(before, {"first": "missing"})
        self.assertEqual(calls, [("deploy", "first"), ("activate", ("first",))])
        self.assertEqual(after, {"first": "active"})

    def test_inert_market_is_activated_without_deployment(self):
        _, calls, _ = self.exercise({"first": "inert"})
        self.assertEqual(calls, [("activate", ("first",))])

    def test_active_markets_have_no_setup_transactions(self):
        _, calls, _ = self.exercise({"first": "active", "second": "active"})
        self.assertEqual(calls, [])

    def test_mixed_markets_are_handled_independently(self):
        before, calls, after = self.exercise({"first": "active", "second": "inert", "third": "missing"})
        self.assertEqual(before, {"first": "active", "second": "inert", "third": "missing"})
        self.assertEqual(calls, [("deploy", "third"), ("activate", ("second", "third"))])
        self.assertTrue(all(state == "active" for state in after.values()))

    def test_failed_activation_does_not_proceed_to_tests(self):
        with self.assertRaisesRegex(RuntimeError, "activation did not create"):
            module.prepare_markets(["first"], lambda _: True, lambda _: self.fail("must not deploy"),
                                   lambda _: False, lambda: None)

    def test_deployment_conflict_does_not_get_activated(self):
        with self.assertRaisesRegex(RuntimeError, "unexpectedly bind"):
            module.prepare_markets(["first"], lambda _: False, lambda _: None, lambda _: True,
                                   lambda: self.fail("must not activate"))

    def test_recorded_market_rpc_error_is_not_treated_as_missing_deployment(self):
        def broken(_):
            raise RuntimeError("broken RPC")
        with self.assertRaisesRegex(RuntimeError, "broken RPC"):
            module.prepare_markets(["first"], lambda _: True, lambda _: self.fail("must not deploy"),
                                   broken, lambda: self.fail("must not activate"))


class MarketDiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / "script/config/mainnet"
        self.artifacts = self.root / "deployed/mainnet/markets"
        (self.config / "markets").mkdir(parents=True)
        self.artifacts.mkdir(parents=True)

    def test_union_includes_future_configs_and_artifact_only_markets(self):
        (self.config / "protocol.toml").write_text('[provision]\nmarkets = ["future", "existing"]\n')
        (self.config / "markets/future.toml").write_text('[market]\nrole = "future"\n')
        for name in ["existing", "artifact-only"]:
            (self.artifacts / f"{name}.toml").write_text('[market]\n')
        self.assertEqual(module.discover_markets(self.root, "mainnet", "mainnet"),
                         ["artifact-only", "existing", "future"])

    def test_empty_market_set_fails(self):
        (self.config / "protocol.toml").write_text('[provision]\nmarkets = []\n')
        with self.assertRaisesRegex(ValueError, "No configured"):
            module.discover_markets(self.root, "mainnet", "mainnet")

    def test_missing_config_for_undeployed_market_fails(self):
        (self.config / "protocol.toml").write_text('[provision]\nmarkets = ["missing"]\n')
        with self.assertRaises(FileNotFoundError):
            module.discover_markets(self.root, "mainnet", "mainnet")

    def test_resource_names_cannot_escape_workspace(self):
        for value in ["..", ".", "../other", "a/b", ""]:
            with self.subTest(value=value), self.assertRaises(ValueError):
                module.name(value)


class WorkspaceTests(unittest.TestCase):
    def test_preparation_cannot_overwrite_original_artifacts_or_copy_local_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            source, target = Path(directory) / "source", Path(directory) / "target"
            source.mkdir()
            target.mkdir()
            (source / "lib").mkdir()
            run = source / "deployed/mainnet"
            run.mkdir(parents=True)
            (run / "protocol.toml").write_text("original")
            (source / "deployed/other").mkdir()
            (source / ".env").write_text("private")
            (source / ".aws").mkdir()
            (source / ".aws/credentials").write_text("private")
            module.copy_workspace(source, target, "mainnet")
            (target / "deployed/mainnet/protocol.toml").write_text("fork-only")
            self.assertEqual((run / "protocol.toml").read_text(), "original")
            self.assertFalse((target / ".env").exists())
            self.assertFalse((target / ".aws").exists())
            self.assertFalse((target / "deployed/other").exists())
            self.assertEqual((target / "lib").resolve(), (source / "lib").resolve())
