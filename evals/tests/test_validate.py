"""Python validator must agree with the Swift one on the shared fixtures.

    evals/.venv/bin/python -m unittest discover -s evals/tests
"""
import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from inky_eval import validate  # noqa: E402
from inky_eval.client import ActionScanner  # noqa: E402
from inky_eval.score import norm_text, text_ok, fn_matches, make_fn  # noqa: E402

FIXTURES = ROOT.parent / "shared/fixtures"


class ValidatorParity(unittest.TestCase):
    def test_shared_fixtures(self):
        cases = json.loads((FIXTURES / "validation/cases.json").read_text())["cases"]
        for c in cases:
            fixed, problem = validate.check(c["action"])
            if c["valid"]:
                self.assertIsNone(problem, c["name"])
            else:
                self.assertIsNotNone(problem, c["name"])
                if c.get("problem"):
                    self.assertIn(c["problem"], problem, c["name"])

    def test_removal_ids(self):
        self.assertEqual(validate.resolve_id("M2", 3), "m2")
        self.assertIsNone(validate.resolve_id("m4", 3))
        self.assertTrue(validate.response_problems({"removeAnnotations": ["m9"], "actions": []}, 1))


class Scanner(unittest.TestCase):
    def test_actions_close_incrementally(self):
        text = (FIXTURES / "all_actions.json").read_text()
        s = ActionScanner()
        found = []
        for i in range(0, len(text), 7):
            found += s.feed(text[i:i + 7])
        self.assertEqual(len(found), 9)


class Scoring(unittest.TestCase):
    def test_text_normalization(self):
        self.assertTrue(text_ok("3x²", ["3x^2", "3x²"]))
        self.assertTrue(text_ok("6 N", ["6"]))
        self.assertTrue(text_ok("1,000", ["1000"]))
        self.assertFalse(text_ok("12", ["56"]))
        self.assertEqual(norm_text("x² + C"), norm_text("x^2+c").replace("^", ""))

    def test_function_match(self):
        xs = [i / 4 for i in range(-20, 21)]
        self.assertTrue(fn_matches("x**2 - 4*x + 3", make_fn("Math.pow(x,2)-4*x+3"), xs))
        self.assertTrue(fn_matches("100*exp(-0.5*x)", make_fn("N0*Math.exp(-k*x)", {"N0": 100, "k": 0.5}), xs))
        self.assertFalse(fn_matches("2*sin(3*x)", make_fn("Math.sin(3*x)"), xs))


if __name__ == "__main__":
    unittest.main()
