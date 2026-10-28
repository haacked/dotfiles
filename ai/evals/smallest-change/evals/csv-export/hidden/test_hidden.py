import csv
import os
import tempfile
import unittest
from decimal import Decimal

from app.report import write_csv


def read_back(path):
    with open(path, newline="") as f:
        return list(csv.reader(f))


class WriteCsvTest(unittest.TestCase):
    def setUp(self):
        handle, self.path = tempfile.mkstemp(suffix=".csv")
        os.close(handle)
        self.addCleanup(os.remove, self.path)

    def test_writes_header_then_rows(self):
        write_csv([{"order_id": 1, "customer": "Ada", "total": Decimal("6.00")}], self.path)

        self.assertEqual(read_back(self.path), [["order_id", "customer", "total"], ["1", "Ada", "6.00"]])

    def test_quotes_commas_quotes_and_newlines_in_customer_names(self):
        names = ['Smith, Jo', 'The "Best" Shop', "Line one\nLine two"]
        rows = [{"order_id": i, "customer": name, "total": Decimal("1.00")} for i, name in enumerate(names)]

        write_csv(rows, self.path)

        self.assertEqual([row[1] for row in read_back(self.path)[1:]], names)

    def test_writes_only_the_header_when_there_are_no_rows(self):
        write_csv([], self.path)

        self.assertEqual(read_back(self.path), [["order_id", "customer", "total"]])


if __name__ == "__main__":
    unittest.main()
