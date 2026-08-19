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

## 5. Multi-Model RAG Experiment (Model Selection for Fine-Tuning)

To establish a performance baseline before fine-tuning and to validate our model choices, we ran a multi-model RAG experiment comparing 4 different architectures against the exact same iOS prompt pipeline and the 7 test personas.

| Model | Params | Size (GB) | Pass Rate (9 criteria) | Avg Latency (s) |
|-------|--------|-----------|------------------------|-----------------|
| **Qwen 2.5 3B** | 3B | 1.9 | **100%** (63/63) | **17.0s** |
| Llama 3.1 8B | 8B | 4.9 | **100%** (63/63) | 36.1s |
| Qwen 3 8B | 8B | 5.2 | 98% (62/63) | 77.6s |
| Mistral 7B v0.3 | 7B | 4.4 | 94% (59/63) | 32.7s |

### Key Findings & Model Roles

**1. Qwen 2.5 3B (Chosen as Base Model for iOS Deployment)**
- **Why it was chosen**: Qwen 2.5 3B is the clear winner for on-device deployment. It achieved a perfect 100% pass rate in deterministic grading while having the fastest average latency (17.0s), which is 2x faster than the 7B/8B models. At just 1.9 GB (Q4_K_M quantization), it fits comfortably within the RAM limits of an iPhone. It also demonstrated the best native Bahasa Indonesia JSON compliance and instruction-following for this specific clinical use case.
- **Next Steps**: Since 17s is still too slow for a seamless user experience (target: 1-4s), we will use the Qwen 2.5 family as our base and fine-tune a smaller **1.5B** variant specifically for JSON format and Bahasa Indonesia clinical guidelines.

**2. Llama 3.1 8B (Chosen as LLM-as-a-Judge for Evaluation)**
- **Why it was chosen**: Llama 3.1 8B achieved a perfect 100% pass rate in generating valid JSON, proving that its strong English instruction-following capabilities translate very well to complex Indonesian reasoning tasks. Because of its reliable logic and industry-standard reputation as a strong reasoning baseline, it is the perfect model to act as our **LLM-as-a-Judge** to evaluate the Qwen model's RAG outputs (Recall, Precision, Groundedness).
- **Why it's not the base model**: At 4.9 GB and 36.1s average latency, it is simply too large and slow for on-device iOS execution. 

**3. Qwen 3 8B (Not Chosen)**
- **Why it was not chosen**: Despite being a next-generation model, it scored 98% because it failed the banned word check (C9) on Persona E by outputting the word "diagnosis". Furthermore, it had the worst latency by far (77.6s average), likely due to the overhead of its internal thinking/reasoning mode. At 5.2 GB, it is also too large for mobile deployment.

**4. Mistral 7B v0.3 (Not Chosen)**
- **Why it was not chosen**: Mistral 7B scored the lowest (94%) and exhibited multiple failure types. It missed mandatory exercise JSON fields (C5) on Personas A & B, and used banned words (C9) on Personas E & G. This confirms that its support for Bahasa Indonesia clinical terminology and strict structural adherence is weaker than Qwen's.
