# Sarc-o-Meter LLM Evaluation Report

**Date**: 2026-08-13
**Generator Model**: Qwen 2.5:3b (via Ollama)
**Judge Model**: Llama 3.1:8b (via Ollama)
**Personas Evaluated**: 7 (including the new severe risk profile with balance/dizziness)

## 1. System Updates & Fixes
- **Revised Clinical History**: Updated questions to be more specific regarding heart conditions, balance/dizziness, and routine medication interactions based on stakeholder feedback.
- **Dynamic Retrieval Limits**: Increased the context window for high-risk users.
  - Severe / High Risk: 6 chunks
  - Mid Risk: 4 chunks
  - Low Risk: 3 chunks
- **Safety Chunk Pinning**: For any user with a severe risk or red flag, safety-critical chunks (`kb_contraindication_01` and `kb_risk_high_severe_01`) are prioritized and pinned at the top of the context window.
- **1-Exercise Constraint**: Added strict rules in the `OnDeviceRAG` prompt to limit severe/mobilityOnly users to a single, gentle exercise (Calf Raise).

---

## 2. Generator Evaluation (Deterministic Grading)
**Overall Pass Rate: 100% (63/63 checks passed)**

The 3B model flawlessly followed the JSON schema, adhered to the exercise constraints, and produced valid, structured outputs for all personas.

| Persona | Risk Level | Score | Exercises Generated |
|---------|-----------|-------|-----------|
| A — Healthy 45F | Low | 9/9 | 3 (✅) |
| B — 62M Possible Sarcopenia | Mid | 9/9 | 3 (✅) |
| C — 72F Low Muscle + Low Strength | High | 9/9 | 3 (✅) |
| D — 78M Severe (all abnormal + obesity) | Severe | 9/9 | **1** (✅) |
| E — 68F Surgery + Heart Condition | Severe + mobilityOnly | 9/9 | **1** (✅) |
| F — 55M Balance/Dizziness + Skipped Tests | Severe | 9/9 | **1** (✅) |
| G — 70F Severe + Balance + Meds *(new)* | Severe | 9/9 | **1** (✅) |

*Note: Personas D, E, F, and G correctly received only 1 exercise (Calf Raise) as dictated by their severe risk profiles.*

---

## 3. LLM-as-a-Judge Evaluation (RAG Quality)

By increasing the chunk limits for high-risk users and pinning safety chunks, we successfully traded some precision for a **massive boost in recall and groundedness for critical cases**.

| Metric | Before Fix (limit=3) | After Fix (dynamic limits) | Delta |
|--------|----------------------|----------------------------|-------|
| **Recall@K** | 0.56 | **0.75** | **+0.19** 🚀 |
| **Groundedness** (1-5) | 3.1 | **3.3** | **+0.2** 📈 |
| **Precision@K** | 0.80 | 0.52 | -0.28 (expected) |
| **Correctness** (1-5) | 2.7 | 2.6 | -0.1 |
| **Relevance** (1-5) | 4.0 | 4.0 | — |

### Impact of Dynamic Retrieval
1. **Recall Increased Significantly**: Severe cases are now consistently retrieving 70-80% of all relevant knowledge instead of missing critical pieces.
2. **Groundedness Improved**: For the most critical persona (Persona G), the judge score for Groundedness doubled from 2/5 to 4/5. Pinning the safety-critical chunks prevents the 3B model from hallucinating clinical justifications and forces it to cite actual safety rules.
3. **Precision Trade-off**: The drop in Precision@K is mathematically expected. When we pull 6 chunks instead of 3, the denominator increases, but because there are only so many "truly relevant" chunks, the precision drops. This is a worthwhile tradeoff for medical safety.

---

## 4. Pending Issues: False Penalties in Judge Rubric
The Llama 3.1 judge continues to give low "Correctness" scores (1-2 out of 5) for the severe risk personas. Reading its grading logic, the judge is heavily penalizing the output for "lacking exercise variety" and "only prescribing 1 exercise".

Because the app is operating exactly as designed by the stakeholder (prescribing only 1 very gentle exercise for severe cases), this low Correctness score is a **false negative** caused by the generic Judge LLM's bias about what a "complete workout routine" should look like.

**Next Step**: The Judge's grading prompt has been updated to explicitly instruct it that prescribing a single, low-intensity exercise is the medically correct action for severe/red-flag users.

---

## 5. Inference Performance (Qwen 2.5:3b)

Before transitioning to fine-tuning, we measured the baseline on-device inference latency using the current `Qwen 2.5:3b` model via Ollama. 

| Persona | Risk Level | Output Length | Inference Time |
|---------|-----------|---------------|----------------|
| A — Healthy 45F | Low | 3 Exercises | **19.1s** |
| B — 62M Possible Sarcopenia | Mid | 3 Exercises | **20.0s** |
| C — 72F Low Muscle + Low Strength | High | 3 Exercises | **22.3s** |
| D — 78M Severe (all abnormal + obesity) | Severe | 1 Exercise | **14.1s** |
| E — 68F Surgery + Heart Condition | Severe | 1 Exercise | **15.8s** |
| F — 55M Balance/Dizziness + Skipped Tests | Severe | 1 Exercise | **12.1s** |
| G — 70F Severe + Balance + Meds *(new)* | Severe | 1 Exercise | **13.8s** |

**Performance Summary**:
- **Average Latency (Full Plan - 3 Exercises)**: ~20.5 seconds
- **Average Latency (Restricted Plan - 1 Exercise)**: ~13.9 seconds
- **Overall Average**: ~16.7 seconds

**Conclusion on Latency**:
An inference time of 16–22 seconds is acceptable for an offline background task, but it presents a poor UX if the user is waiting on a loading screen in a mobile app. 
- The large prompt size (RAG context + strict JSON rules) contributes to higher prefill latency.
- Migrating to a fine-tuned **1.5B** or **0.5B** model would drastically reduce this inference time down to **1–4 seconds**, making the user experience much smoother on iOS devices.
