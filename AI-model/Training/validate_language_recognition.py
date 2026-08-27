from __future__ import annotations

import csv
import sys
from collections import Counter, defaultdict
from pathlib import Path

import pandas as pd

ROOT = Path(__file__).resolve().parents[1]
PROJECT_ROOT = ROOT.parent
BACKEND = PROJECT_ROOT / 'Backend'
EVAL = ROOT / 'Evaluation'
DATA = ROOT / 'Data' / 'language_validation_cases.csv'
EVAL.mkdir(parents=True, exist_ok=True)

sys.path.insert(0, str(BACKEND))
from services.language_service import detect_language_details  # noqa: E402


def main():
    df = pd.read_csv(DATA)
    rows = []
    correct = 0
    confusion = defaultdict(Counter)

    for _, row in df.iterrows():
        expected = str(row['expected_language'])
        text = str(row['ticket_text'])
        details = detect_language_details(text)
        predicted = details['language']
        passed = predicted == expected
        correct += int(passed)
        confusion[expected][predicted] += 1
        rows.append({
            'expected_language': expected,
            'predicted_language': predicted,
            'passed': passed,
            'singlish_score': details.get('singlish_score', 0),
            'english_score': details.get('english_score', 0),
            'reason': details.get('reason', ''),
            'ticket_text': text,
        })

    result_df = pd.DataFrame(rows)
    result_df.to_csv(EVAL / 'language_recognition_results.csv', index=False, encoding='utf-8-sig')

    labels = ['English', 'Sinhala', 'Singlish', 'Mixed']
    matrix = []
    for expected in labels:
        matrix.append([confusion[expected][predicted] for predicted in labels])
    pd.DataFrame(matrix, index=labels, columns=labels).to_csv(EVAL / 'language_recognition_confusion_matrix.csv')

    accuracy = correct / len(df) if len(df) else 0.0
    by_language = []
    for language, group in result_df.groupby('expected_language'):
        by_language.append({
            'language_type': language,
            'rows': len(group),
            'correct': int(group['passed'].sum()),
            'accuracy': float(group['passed'].mean()),
        })
    pd.DataFrame(by_language).to_csv(EVAL / 'language_recognition_by_language.csv', index=False)

    summary = [
        'HelaFixIt AI language recognition validation',
        f'Validation examples {len(df)}',
        f'Correct predictions {correct}',
        f'Overall accuracy {accuracy:.3%}',
    ]
    for item in sorted(by_language, key=lambda x: x['language_type']):
        summary.append(f"{item['language_type']} accuracy {item['accuracy']:.3%} ({item['correct']}/{item['rows']})")
    (EVAL / 'language_recognition_summary.txt').write_text('\n'.join(summary) + '\n', encoding='utf-8')

    metadata_path = ROOT / 'Models' / 'model_metadata.json'
    if metadata_path.exists():
        try:
            import json
            metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
            metadata['language_recognition_validation_rows'] = int(len(df))
            metadata['language_recognition_accuracy'] = round(float(accuracy), 5)
            metadata_path.write_text(json.dumps(metadata, indent=2, ensure_ascii=False), encoding='utf-8')
        except Exception:
            pass

    print('\n'.join(summary))

    failed = result_df[~result_df['passed']]
    if not failed.empty:
        print('\nMisclassified examples')
        for _, item in failed.head(20).iterrows():
            print(f"{item['expected_language']} -> {item['predicted_language']} | {item['ticket_text']}")


if __name__ == '__main__':
    main()
