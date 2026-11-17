import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import asc  # noqa: E402
from asc import app_id_for, highest_build, next_build_number, should_retry, what_to_test_text  # noqa: E402


class AscTests(unittest.TestCase):
    def test_highest_ignores_non_integer(self):
        self.assertEqual(highest_build(["198", "1.4.1", "abc", "200", "199"]), 200)

    def test_highest_empty(self):
        self.assertIsNone(highest_build([]))

    def test_next_build_from_asc(self):
        self.assertEqual(next_build_number(201, 197), 202)

    def test_next_build_floor_wins(self):
        self.assertEqual(next_build_number(150, 201), 202)

    def test_next_build_no_history(self):
        self.assertEqual(next_build_number(None, 201), 202)

    def test_what_to_test_empty(self):
        self.assertEqual(what_to_test_text([]), "No changes since the previous build.")

    def test_what_to_test_lines(self):
        self.assertEqual(what_to_test_text(["fix: b", "feat: a"]), "- fix: b\n- feat: a")

    def test_what_to_test_truncates(self):
        text = what_to_test_text([f"commit {i} " + "x" * 80 for i in range(200)], limit=1000)
        self.assertLessEqual(len(text), 1000)
        self.assertTrue(text.splitlines()[-1].startswith("- … and "))

    def test_app_lookup_requires_exact_bundle_id(self):
        apps = [{"id": "mac", "attributes": {"bundleId": "com.singular.coderelay.mac"}},
                {"id": "ios", "attributes": {"bundleId": "com.singular.coderelay"}}]
        self.assertEqual(app_id_for(apps, "com.singular.coderelay"), "ios")
        self.assertEqual(app_id_for(apps, "com.singular.coderelay.mac"), "mac")
        self.assertIsNone(app_id_for(apps[:1], "com.singular.coderelay"))


class RetryTests(unittest.TestCase):
    def test_reads_retry_server_and_network_errors(self):
        for status in (None, 429, 500, 502, 503, 504):
            self.assertTrue(should_retry("GET", status), status)

    def test_client_errors_and_writes_do_not_retry(self):
        for status in (400, 401, 403, 404, 409):
            self.assertFalse(should_retry("GET", status), status)
        for method in ("POST", "PATCH", "DELETE"):
            self.assertFalse(should_retry(method, 500), method)

    def _run(self, outcomes, method="GET"):
        import io
        import urllib.error
        from unittest import mock
        calls, sleeps = [], []

        def fake_urlopen(req, timeout):
            calls.append(req.get_method())
            outcome = outcomes[len(calls) - 1]
            if isinstance(outcome, int):
                raise urllib.error.HTTPError(req.full_url, outcome, "err", {}, io.BytesIO(b"{}"))
            resp = mock.MagicMock()
            resp.__enter__.return_value.read.return_value = outcome
            return resp

        with mock.patch.object(asc, "_token", return_value="t"), \
             mock.patch.object(asc.urllib.request, "urlopen", fake_urlopen), \
             mock.patch.object(asc.time, "sleep", sleeps.append), \
             mock.patch("sys.stderr", io.StringIO()):
            try:
                return asc._request(method, "/v1/apps"), calls, sleeps
            except SystemExit as e:
                return e, calls, sleeps

    def test_transient_500_then_success(self):
        result, calls, sleeps = self._run([500, 500, b'{"data": []}'])
        self.assertEqual(result, {"data": []})
        self.assertEqual(len(calls), 3)
        self.assertEqual(sleeps, [10, 20])

    def test_gives_up_after_the_last_delay(self):
        result, calls, sleeps = self._run([500] * 6)
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(len(calls), 6)
        self.assertEqual(sleeps, list(asc.RETRY_DELAYS))

    def test_404_and_post_fail_at_once(self):
        result, calls, _ = self._run([404])
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(len(calls), 1)
        result, calls, _ = self._run([500], method="POST")
        self.assertIsInstance(result, SystemExit)
        self.assertEqual(len(calls), 1)


if __name__ == "__main__":
    unittest.main()
