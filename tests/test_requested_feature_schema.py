import pandas as pd

from compare_segmentation_techniques import build_feature_schema


def test_feature_schema_restricts_segmentation_to_requested_columns():
    dev_df = pd.DataFrame(
        {
            "default_flag": [0, 1, 0, 1],
            "pd_score": [0.1, 0.8, 0.2, 0.9],
            "ead": [100, 200, 150, 250],
            "age": [25, 35, 45, 55],
            "bureau_score": [700, 650, 600, 680],
            "dti": [30, 40, 50, 35],
            "utilization": [20, 60, 80, 45],
            "region": ["North", "South", "North", "South"],
            "employment_type": ["Salaried", "Business", "Salaried", "SelfEmployed"],
            "other_feature": [1, 2, 3, 4],
        }
    )

    schema = build_feature_schema(dev_df)

    assert schema.numeric_cols == ["age", "bureau_score", "dti", "utilization"]
    assert schema.categorical_cols == ["region", "employment_type"]
    # build_feature_schema() unconditionally appends "customer_id" to
    # exclude_cols regardless of whether the dataframe actually has that
    # column -- harmless (excluding a nonexistent column name is a no-op),
    # but it does mean it always appears here.
    assert schema.exclude_cols == ["other_feature", "default_flag", "pd_score", "ead", "customer_id"]
