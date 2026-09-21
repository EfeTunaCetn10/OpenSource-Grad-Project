import unittest

from prepare_insect_detect import assign_groups, capture_day, make_groups


class CaptureSplitTests(unittest.TestCase):
    def test_both_timestamp_formats(self):
        self.assertEqual(capture_day("20230517_10-55-26.014912_81_crop.jpg"), "20230517")
        self.assertEqual(capture_day("20221006_11-25-36-817146_raw_jpg.rf.abc.jpg"), "20221006")

    def test_invalid_date_or_filename_is_rejected(self):
        for name in ("unknown.jpg", "20230230_10-00-00.123_1_crop.jpg"):
            with self.assertRaises(ValueError):
                capture_day(name)

    def test_duplicate_links_merge_whole_days_transitively(self):
        samples = [dict(day=day, sha256=digest) for day, digest in
                   [("a", "x"), ("b", "x"), ("b", "y"), ("c", "y"), ("d", "z")]]
        groups = make_groups(samples)
        self.assertEqual(sorted(len(g) for g in groups.values()), [1, 4])

    def test_repeatable_and_every_class_present(self):
        groups = {str(i): [{"class": c} for c in ("a", "b")] for i in range(20)}
        first = assign_groups(groups, ["a", "b"], 42, trials=20)
        self.assertEqual(first, assign_groups(groups, ["a", "b"], 42, trials=20))
        self.assertEqual(set(first), set(groups))
        self.assertEqual(set(first.values()), {"train", "val", "test"})

    def test_unsplittable_class_fails(self):
        groups = {"1": [{"class": "rare"}], "2": [{"class": "common"}],
                  "3": [{"class": "common"}]}
        with self.assertRaises(ValueError):
            assign_groups(groups, ["rare", "common"], 42, trials=10)


if __name__ == "__main__":
    unittest.main()
