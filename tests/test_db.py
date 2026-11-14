import tempfile
import unittest
from pathlib import Path

from sqlalchemy import create_engine
from sqlalchemy.orm import sessionmaker

from backend import db


class DatabaseTests(unittest.TestCase):
    def setUp(self):
        self.database = tempfile.NamedTemporaryFile(suffix=".db")
        db.engine = create_engine(f"sqlite:///{Path(self.database.name)}", connect_args={"check_same_thread": False})
        db.Session = sessionmaker(db.engine, expire_on_commit=False)
        db.create_tables()

    def tearDown(self):
        self.database.close()

    def test_saves_lists_and_reads_a_comparison(self):
        result = {
            "baseline": "demo",
            "run": "compare_demo_test",
            "score": 2,
            "level": "normal",
            "matches": False,
            "features_compared": 10,
            "outside_range": 1,
            "findings": [],
            "differences": [],
        }

        comparison_id = db.save_comparison(result)
        total, page = db.list_comparisons()
        found = db.get_comparison(comparison_id)

        self.assertEqual(total, 1)
        self.assertEqual(page[0]["baseline"], "demo")
        self.assertEqual(found["id"], comparison_id)
        self.assertEqual(found["baseline"], result["baseline"])
        self.assertEqual(found["score"], result["score"])
        self.assertEqual(found["differences"], result["differences"])


if __name__ == "__main__":
    unittest.main()
