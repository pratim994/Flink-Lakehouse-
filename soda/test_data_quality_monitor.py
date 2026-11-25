import unittest
from unittest.mock import patch

import data_quality_monitor as monitor


class QualityMonitorTests(unittest.TestCase):
    @patch.object(monitor, "query", side_effect=[[[1]]] + [[[0]]] * 6 + [[[900]]] + [[[0]]] * 6)
    def test_valid_counts_pass(self, query):
        self.assertTrue(all(ok for _, _, ok in monitor.run_checks()))
        self.assertEqual(len(query.call_args_list), 14)

    @patch.object(monitor, "query")
    def test_invalid_rows_fail_relevant_checks(self, query):
        # In the order defined by run_checks: duplicate SKU, bad format, bad
        # quantity/price, dangling product reference, and stale data.
        query.side_effect = [[[4]], [[0]], [[0]], [[0]], [[0]], [[2]], [[1]], [[900]], [[0]], [[0]], [[3]], [[1]], [[2]], [[1]]]
        results = dict((name, passed) for name, _, passed in monitor.run_checks())
        self.assertFalse(results["products.sku unique"])
        self.assertFalse(results["products SKU format"])
        self.assertFalse(results["sales qty positive"])
        self.assertFalse(results["sales price positive"])
        self.assertFalse(results["sales product reference"])
        self.assertFalse(results["sales freshness <= 8760h"])


if __name__ == "__main__":
    unittest.main()
