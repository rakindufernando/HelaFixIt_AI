from __future__ import annotations

import json
import time
from pathlib import Path

import matplotlib.pyplot as plt
import pandas as pd
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.pipeline import FeatureUnion
from sklearn.metrics import accuracy_score, classification_report, confusion_matrix, f1_score
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.linear_model import SGDClassifier

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / 'Data' / 'maintenance_tickets.csv'
CHALLENGE = ROOT / 'Data' / 'challenge_test.csv'
EVAL = ROOT / 'Evaluation'
MODELS = ROOT / 'Models'
EVAL.mkdir(parents=True, exist_ok=True)
SEED = 6035



def build_model_text(df):
    # Use the same text context that the Flask application supplies during prediction.
    return (
        df['ticket_text'].fillna('').astype(str)
        + '. Area ' + df['area'].fillna('').astype(str)
        + '. Asset ' + df['asset_type'].fillna('').astype(str)
    )

def build_vectorizer():
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


def score(y, pred):
    return {
        'accuracy': float(accuracy_score(y, pred)),
        'macro_f1': float(f1_score(y, pred, average='macro')),
        'weighted_f1': float(f1_score(y, pred, average='weighted')),
    }


def save_confusion(y, pred, labels, stem, title):
    cm = confusion_matrix(y, pred, labels=labels)
    pd.DataFrame(cm, index=labels, columns=labels).to_csv(EVAL / f'{stem}.csv')
    fig, ax = plt.subplots(figsize=(9, 7))
    image = ax.imshow(cm)
    ax.set_title(title)
    ax.set_xlabel('Predicted')
    ax.set_ylabel('Actual')
    ax.set_xticks(range(len(labels)), labels=labels, rotation=45, ha='right')
    ax.set_yticks(range(len(labels)), labels=labels)
    for i in range(len(labels)):
        for j in range(len(labels)):
            ax.text(j, i, str(cm[i, j]), ha='center', va='center', fontsize=8)
    fig.colorbar(image, ax=ax)
    fig.tight_layout()
    fig.savefig(EVAL / f'{stem}.png', dpi=180)
    plt.close(fig)


def main():
    started = time.time()
    df = pd.read_csv(DATA)
    challenge = pd.read_csv(CHALLENGE)
    if len(df) != 60000:
        raise SystemExit(f'Expected 60,000 dataset rows, found {len(df):,}.')

    splitter = StratifiedGroupKFold(n_splits=5, shuffle=True, random_state=SEED)
    train_idx, test_idx = next(splitter.split(df, y=df['category'], groups=df['scenario_id']))
    train = df.iloc[train_idx].copy()
    test = df.iloc[test_idx].copy()

    print('Creating leakage-reduced group holdout...')
    vectorizer = build_vectorizer()
    X_train = vectorizer.fit_transform(build_model_text(train))
    X_test = vectorizer.transform(build_model_text(test))
    X_challenge = vectorizer.transform(build_model_text(challenge))

    print('Evaluating category model...')
    category_model = build_classifier()
    category_model.fit(X_train, train['category'])
    category_pred = category_model.predict(X_test)
    category_challenge_pred = category_model.predict(X_challenge)
    cat = score(test['category'], category_pred)
    cat_ch = score(challenge['category'], category_challenge_pred)

    print('Evaluating priority model...')
    priority_model = build_classifier()
    priority_model.fit(X_train, train['priority'])
    priority_pred = priority_model.predict(X_test)
    priority_challenge_pred = priority_model.predict(X_challenge)
    pri = score(test['priority'], priority_pred)
    pri_ch = score(challenge['priority'], priority_challenge_pred)

    category_labels = sorted(df['category'].unique().tolist())
    priority_labels = ['Emergency', 'High', 'Medium', 'Low']
    save_confusion(test['category'], category_pred, category_labels, 'category_confusion_matrix', 'Category Model Group-Holdout Confusion Matrix')
    save_confusion(test['priority'], priority_pred, priority_labels, 'priority_confusion_matrix', 'Priority Model Group-Holdout Confusion Matrix')

    (EVAL / 'category_classification_report.json').write_text(
        json.dumps(classification_report(test['category'], category_pred, output_dict=True, zero_division=0), indent=2, ensure_ascii=False), encoding='utf-8')
    (EVAL / 'priority_classification_report.json').write_text(
        json.dumps(classification_report(test['priority'], priority_pred, output_dict=True, zero_division=0), indent=2, ensure_ascii=False), encoding='utf-8')

    language_rows = []
    for task, actual_col, predictions in [('Category', 'category', category_pred), ('Priority', 'priority', priority_pred)]:
        temp = test[['language_type', actual_col]].copy()
        temp['predicted'] = predictions
        for language, group in temp.groupby('language_type'):
            language_rows.append({
                'task': task, 'language_type': language, 'rows': len(group),
                'accuracy': accuracy_score(group[actual_col], group['predicted']),
                'macro_f1': f1_score(group[actual_col], group['predicted'], average='macro', zero_division=0),
            })
    pd.DataFrame(language_rows).to_csv(EVAL / 'accuracy_by_language.csv', index=False)

    errors = []
    for task, target, pred in [('Category', 'category', category_pred), ('Priority', 'priority', priority_pred)]:
        actual = test[target].astype(str).to_numpy()
        for pos, (a, p) in enumerate(zip(actual, pred)):
            if a != p:
                row = test.iloc[pos]
                errors.append({
                    'task': task, 'actual': a, 'predicted': p,
                    'language_type': row['language_type'], 'category': row['category'],
                    'priority': row['priority'], 'scenario_id': row['scenario_id'],
                    'ticket_text': row['ticket_text'],
                })
    pd.DataFrame(errors).to_csv(EVAL / 'misclassified_examples.csv', index=False, encoding='utf-8-sig')

    metrics = {
        'dataset_rows': int(len(df)),
        'challenge_rows': int(len(challenge)),
        'test_rows_for_evaluation': int(len(test)),
        'split_method': 'StratifiedGroupKFold with non-overlapping scenario_id groups between evaluation train and test.',
        'category_accuracy': round(cat['accuracy'], 5),
        'category_macro_f1': round(cat['macro_f1'], 5),
        'priority_accuracy': round(pri['accuracy'], 5),
        'priority_macro_f1': round(pri['macro_f1'], 5),
        'category_challenge_accuracy': round(cat_ch['accuracy'], 5),
        'category_challenge_macro_f1': round(cat_ch['macro_f1'], 5),
        'priority_challenge_accuracy': round(pri_ch['accuracy'], 5),
        'priority_challenge_macro_f1': round(pri_ch['macro_f1'], 5),
        'evaluation_seconds': round(time.time() - started, 2),
        'note': 'Evaluation results describe performance on the prepared holdout and challenge datasets. Real user wording may still require review.',
    }
    (EVAL / 'metrics.json').write_text(json.dumps(metrics, indent=2, ensure_ascii=False), encoding='utf-8')
    pd.DataFrame([
        {'task': 'Category', 'evaluation': 'Group holdout', **cat},
        {'task': 'Category', 'evaluation': 'Separate challenge set', **cat_ch},
        {'task': 'Priority', 'evaluation': 'Group holdout', **pri},
        {'task': 'Priority', 'evaluation': 'Separate challenge set', **pri_ch},
    ]).to_csv(EVAL / 'model_comparison.csv', index=False)

    summary = [
        'HelaFixIt AI model evaluation',
        f"Dataset rows: {len(df):,}",
        f"Evaluation holdout rows: {len(test):,}",
        f"Challenge rows: {len(challenge):,}",
        f"Category accuracy: {cat['accuracy']:.3%}",
        f"Category macro F1: {cat['macro_f1']:.3%}",
        f"Priority accuracy: {pri['accuracy']:.3%}",
        f"Priority macro F1: {pri['macro_f1']:.3%}",
        f"Challenge category accuracy: {cat_ch['accuracy']:.3%}",
        f"Challenge priority accuracy: {pri_ch['accuracy']:.3%}",
        'Evaluation results should be reported together with the test method and dataset used.',
    ]
    (EVAL / 'evaluation_summary.txt').write_text('\n'.join(summary) + '\n', encoding='utf-8')

    metadata_path = MODELS / 'model_metadata.json'
    if metadata_path.exists():
        try:
            metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
            metadata.update(metrics)
            metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding='utf-8')
        except Exception:
            pass

    print('\n'.join(summary))


if __name__ == '__main__':
    main()
