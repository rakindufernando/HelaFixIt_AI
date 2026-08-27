from __future__ import annotations

import json
import platform
import time
from pathlib import Path

import joblib
import numpy as np
import pandas as pd
import sklearn
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.pipeline import FeatureUnion
from sklearn.linear_model import SGDClassifier

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data' / 'maintenance_tickets.csv'
MODELS = ROOT / 'Models'
EVAL_METRICS = ROOT / 'Evaluation' / 'metrics.json'
MODELS.mkdir(parents=True, exist_ok=True)
SEED = 6035



def build_model_text(df):
    # Use the same text context that the Flask application supplies during prediction.
    return (
        df['ticket_text'].fillna('').astype(str)
        + '. Area ' + df['area'].fillna('').astype(str)
        + '. Asset ' + df['asset_type'].fillna('').astype(str)
    )

def build_vectorizer():
    # Word features learn maintenance terms and short phrases. Character features help
    # with Singlish spelling differences such as watura/vatura and wenawa/venawa.
    return FeatureUnion([
        ('word', TfidfVectorizer(
            analyzer='word', ngram_range=(1, 2), min_df=2, max_df=0.995,
            max_features=18000, sublinear_tf=True, token_pattern=r'(?u)\b\w+\b'
        )),
        ('char', TfidfVectorizer(
            analyzer='char_wb', ngram_range=(3, 5), min_df=3,
            max_features=22000, sublinear_tf=True
        )),
    ])


def build_classifier():
    return SGDClassifier(
        loss='log_loss', alpha=1e-5, penalty='l2', class_weight='balanced',
        random_state=SEED, max_iter=70, tol=1e-4, average=True
    )


def main():
    started = time.time()
    df = pd.read_csv(DATA)
    required = {'ticket_text', 'category', 'priority', 'scenario_id', 'language_type', 'area', 'asset_type'}
    missing = required - set(df.columns)
    if missing:
        raise SystemExit(f'Missing dataset columns: {sorted(missing)}')
    if len(df) != 60000:
        raise SystemExit(f'Expected exactly 60,000 rows, found {len(df):,}.')
    if df['ticket_text'].duplicated().any():
        raise SystemExit('Duplicate ticket descriptions detected. Regenerate the dataset before training.')

    print('1/4 Loading 60,000 labelled multilingual tickets...')
    print('2/4 Fitting TF-IDF multilingual text features...')
    vectorizer = build_vectorizer()
    X = vectorizer.fit_transform(build_model_text(df))

    print('3/4 Training category model...')
    category_model = build_classifier()
    category_model.fit(X, df['category'])

    print('4/4 Training priority model and saving artefacts...')
    priority_model = build_classifier()
    priority_model.fit(X, df['priority'])

    joblib.dump(vectorizer, MODELS / 'tfidf_vectorizer.joblib', compress=0)
    joblib.dump(category_model, MODELS / 'category_model.joblib', compress=0)
    joblib.dump(priority_model, MODELS / 'priority_model.joblib', compress=0)

    evaluation = {}
    if EVAL_METRICS.exists():
        try:
            evaluation = json.loads(EVAL_METRICS.read_text(encoding='utf-8'))
        except Exception:
            evaluation = {}

    metadata = {
        'bundle_name': 'HelaFixIt Multilingual Ticket Decision Bundle',
        'version': '6.0.0',
        'training_data_version': 'multilingual-60k-residential-v6.0',
        'dataset_rows': int(len(df)),
        'unique_ticket_text_rows': int(df['ticket_text'].nunique()),
        'scenario_groups': int(df['scenario_id'].nunique()),
        'feature_extraction': 'TF-IDF word 1-2 grams plus character 3-5 grams with multilingual safety and category rules',
        'training_input_context': 'Ticket text with maintenance area and asset context',
        'category_model': 'SGD Classifier with logistic loss',
        'priority_model': 'SGD Classifier with logistic loss',
        'category_labels': sorted(df['category'].unique().tolist()),
        'priority_labels': ['Emergency', 'High', 'Medium', 'Low'],
        'languages': sorted(df['language_type'].unique().tolist()),
        'python_version': platform.python_version(),
        'scikit_learn_version': sklearn.__version__,
        'pandas_version': pd.__version__,
        'numpy_version': np.__version__,
        'training_seconds': round(time.time() - started, 2),
        'evaluation_note': 'Model performance is reported from the separate evaluation script and challenge tests.',
    }
    for key in [
        'category_accuracy', 'category_macro_f1', 'priority_accuracy', 'priority_macro_f1',
        'category_challenge_accuracy', 'category_challenge_macro_f1',
        'priority_challenge_accuracy', 'priority_challenge_macro_f1',
        'test_rows_for_evaluation', 'challenge_rows', 'split_method'
    ]:
        if key in evaluation:
            metadata[key] = evaluation[key]

    (MODELS / 'model_metadata.json').write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding='utf-8')
    print(f"Training complete in {metadata['training_seconds']:.1f} seconds.")
    print('Saved tfidf_vectorizer.joblib, category_model.joblib and priority_model.joblib.')


if __name__ == '__main__':
    main()
