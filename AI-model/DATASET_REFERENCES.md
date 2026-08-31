# HelaFixIt AI Training Dataset References

## 1.0 Introduction

The HelaFixIt AI training dataset was created for the AI-Based Multilingual Apartment Maintenance Ticket Prioritization, Risk Scoring, and Technician Recommendation System. The dataset was not downloaded as a complete ready-made dataset from a single online source. It was prepared specifically for this final development project using project-defined apartment maintenance scenarios and multilingual wording variations.

Online research papers were used to understand building maintenance request classification, maintenance priority handling, Sinhala-English code-mixed text, and Singlish or Romanized Sinhala wording. Official scikit-learn documentation was also used for the machine learning training and evaluation methods used with the dataset.

The academic papers listed below are supporting references for the dataset design. The 60,000 individual dataset records were created for HelaFixIt AI and were not copied directly from these publications.

## 2.0 Training Dataset

The main training dataset is stored in the following location.

`AI-model/Data/maintenance_tickets.csv`

The current dataset contains 60,000 unique labelled apartment maintenance ticket records and 127 main scenario groups. The dataset supports four language styles.

- English
- Sinhala
- Singlish
- Mixed language

The dataset covers 13 maintenance categories.

- Air Conditioning
- Carpentry
- Cleaning
- Drainage
- Electrical
- Fire and Safety
- Gas
- Lift
- Other
- Pest Control
- Plumbing
- Security and Access
- Structural

The dataset uses four priority levels.

- Emergency
- High
- Medium
- Low

Different wording variations were created for the maintenance scenarios so that the AI module could be trained using multilingual apartment maintenance descriptions.

## 3.0 Building Maintenance and Priority References

### Bouabdallaoui et al. 2020

Bouabdallaoui, Y., Lafhaj, Z., Yim, P., Ducoulombier, L. and Bennadji, B. 2020. Natural Language Processing Model for Managing Maintenance Requests in Buildings. *Buildings*, 10(9), 160.

https://www.mdpi.com/2075-5309/10/9/160

This research explains how building maintenance requests can be processed as unstructured text and classified using Natural Language Processing and machine learning. This supported the decision to create labelled maintenance ticket descriptions for issue category prediction in HelaFixIt AI.

### D'Orazio, Di Giuseppe and Bernardini 2022

D'Orazio, M., Di Giuseppe, E. and Bernardini, G. 2022. Automatic detection of maintenance requests: Comparison of Human Manual Annotation and Sentiment Analysis techniques. *Automation in Construction*, 134, 104068.

https://www.sciencedirect.com/science/article/pii/S0926580521005197

This study investigates end-user maintenance requests and maintenance severity. It supported the use of different urgency and priority levels when creating maintenance ticket scenarios for the dataset.

### Ensafi et al. 2023

Ensafi, M., Thabet, W., Afsari, K. and Yang, E. 2023. Challenges and gaps with user-led decision-making for prioritizing maintenance work orders. *Journal of Building Engineering*, 66, 105840.

https://www.sciencedirect.com/science/article/pii/S2352710223000190

This research discusses problems related to manually prioritising maintenance work orders and the information required for maintenance decisions. This supported the use of structured priority labels and maintenance context when creating the HelaFixIt AI dataset.

### D'Orazio, Bernardini and Di Giuseppe 2024

D'Orazio, M., Bernardini, G. and Di Giuseppe, E. 2024. Influence of pre-processing methods on the automatic priority prediction of native-language end-users' maintenance requests through machine learning methods. *Journal of Information Technology in Construction*, 29, pp. 99-116.

https://www.itcon.org/paper/2024/6

This research focuses on automatic priority prediction for native-language maintenance requests using machine learning. It supported the use of labelled priority levels, text preprocessing, and machine learning for priority prediction in HelaFixIt AI.

## 4.0 Sinhala, Singlish and Mixed-Language References

### Kugathasan and Sumathipala 2021

Kugathasan, A. and Sumathipala, S. 2021. Neural Machine Translation for Sinhala-English Code-Mixed Text. *Proceedings of the International Conference on Recent Advances in Natural Language Processing*, pp. 718-726.

https://aclanthology.org/2021.ranlp-1.82/

This research discusses Sinhala-English code-mixed text and the challenges related to limited language resources. It supported the inclusion of Sinhala and English mixed wording in the HelaFixIt AI training dataset.

### Perera et al. 2025

Perera, S., Prabhath, L., Sumanathilaka, T.G.D.K. and Anuradha, I. 2025. IndoNLP 2025 Shared Task: Romanized Sinhala to Sinhala Reverse Transliteration Using BERT. *Proceedings of the First Workshop on Natural Language Processing for Indo-Aryan and Dravidian Languages*, pp. 135-140.

https://aclanthology.org/2025.indonlp-1.16/

This research discusses Romanized Sinhala, which is commonly called Singlish in Sri Lankan digital communication. This supported the inclusion of Sinhala maintenance descriptions written using English characters.

### De Mel et al. 2025

De Mel, Y., Wickramasinghe, K., de Silva, N. and Ranathunga, S. 2025. Sinhala Transliteration: A Comparative Analysis Between Rule-based and Seq2Seq Approaches. *Proceedings of the First Workshop on Natural Language Processing for Indo-Aryan and Dravidian Languages*, pp. 166-173.

https://aclanthology.org/2025.indonlp-1.19/

This research discusses Romanized Sinhala and the different informal patterns that can occur in transliterated Sinhala. It supported the use of different Singlish spelling variations instead of depending on one fixed wording pattern.

## 5.0 Machine Learning and Evaluation References

The following official technical references were used for the AI training and evaluation process. These sources supported the machine learning implementation and did not provide the actual maintenance ticket records.

### TF-IDF Vectorization

scikit-learn developers. *TfidfVectorizer documentation*.

https://scikit-learn.org/stable/modules/generated/sklearn.feature_extraction.text.TfidfVectorizer.html

HelaFixIt AI uses word and character TF-IDF features to convert maintenance ticket text into numerical features that can be processed by the classification models.

### SGDClassifier

scikit-learn developers. *SGDClassifier documentation*.

https://scikit-learn.org/stable/modules/generated/sklearn.linear_model.SGDClassifier.html

The final category and priority prediction models use `SGDClassifier` with logistic loss.

### StratifiedGroupKFold

scikit-learn developers. *StratifiedGroupKFold documentation*.

https://scikit-learn.org/stable/modules/generated/sklearn.model_selection.StratifiedGroupKFold.html

The evaluation process uses grouped splitting so that related wording variations belonging to the same scenario group are kept separate between evaluation training and test groups.

### Classification Report

scikit-learn developers. *Classification report documentation*.

https://scikit-learn.org/stable/modules/generated/sklearn.metrics.classification_report.html

This was used to support the evaluation of the category and priority models using precision, recall, and F1 score.

### Confusion Matrix

scikit-learn developers. *Confusion matrix documentation*.

https://scikit-learn.org/stable/modules/generated/sklearn.metrics.confusion_matrix.html

This was used to review the predicted and actual classes during model evaluation.

## 6.0 Project Files Related to the Dataset

The repository contains the main files used to generate, train, validate, and evaluate the HelaFixIt AI dataset and AI models.

- `AI-model/Data/maintenance_tickets.csv`
- `AI-model/Data/challenge_test.csv`
- `AI-model/Data/language_validation_cases.csv`
- `AI-model/Data/validation_cases.csv`
- `AI-model/Training/generate_dataset.py`
- `AI-model/Training/train_models.py`
- `AI-model/Training/evaluate_models.py`
- `AI-model/Training/test_model_examples.py`
- `AI-model/Training/validate_ai_cases.py`
- `AI-model/Training/validate_language_recognition.py`
- `AI-model/Models/model_metadata.json`

The current dataset version is recorded as `multilingual-60k-residential-v6.0`, and the current model bundle version is `6.0.0`.

## 7.0 Dataset Note

The HelaFixIt AI training dataset is a project-created academic dataset developed for the final development project. The research papers listed in this document were used to support the maintenance domain, maintenance priority design, multilingual language design, and text classification approach.

The 60,000 records were not copied directly from the research papers. They were generated from project-defined apartment maintenance scenarios and multilingual wording variations. Therefore, these references should be considered supporting academic sources rather than the direct source of every individual dataset row.

The final model results describe performance on the prepared project dataset and validation cases. Real apartment maintenance descriptions may contain additional wording and situations that are not represented in the current dataset. Future development can improve the dataset by adding more anonymised real-world apartment maintenance examples and wider user testing.
